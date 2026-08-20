# frozen_string_literal: true

class Vendor < ApplicationRecord
  # Storage column on vendors is `custom_field_values`; the Customizable
  # concern is written against `custom_fields`. Alias bridges the two.
  alias_attribute :custom_fields, :custom_field_values

  include Customizable

  has_secure_password validations: false

  # ----- Associations -----
  belongs_to :company
  belongs_to :default_expense_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true

  # Contractor surface
  has_many :contractor_assignments, dependent: :destroy
  # Phones allowed to unlock the contractor portal with a fingerprint or Face ID.
  has_many :device_sessions, as: :owner, dependent: :destroy

  # Losing access has to reach the phones. Biometric unlock bypasses the
  # credential by design, so a contractor who is deactivated or removed would
  # otherwise keep a device that still opens the portal.
  after_update_commit :revoke_device_sessions_after_access_change,
                      if: -> { saved_change_to_password_digest? || lost_portal_access? }

  # Supplier surface — supplier_parts.supplier_id holds vendor IDs after migration
  has_many :supplier_parts, foreign_key: :supplier_id, dependent: :destroy
  has_many :parts, through: :supplier_parts

  # Polymorphic agreement surface (signable_type/attachable_type rewritten to 'Vendor')
  has_many :agreement_signers,     as: :signable,   dependent: :nullify
  has_many :agreement_attachments, as: :attachable, dependent: :destroy

  # Accounting surface — these tables have a `vendor_id` column after the migration.
  has_many :bills,             dependent: :nullify
  has_many :purchase_orders,   dependent: :nullify
  has_many :recurring_bills,   dependent: :nullify

  # ----- Constants -----
  VENDOR_TYPES = %w[contractor supplier service_provider utility other].freeze
  TRADE_TYPES  = %w[
    general electrical plumbing hvac foundation transport skirting roofing
    materials_supplier freight_company equipment_rental lumber concrete appliances other
  ].freeze
  STATUSES = %w[active inactive suspended].freeze

  # How a contractor's SMS consent was obtained. 'contractor_portal' is the
  # contractor flipping it themselves; 'dealer_recorded' is a dealer attesting to
  # consent given verbally or in a signed agreement; 'import' is bulk-loaded and
  # the weakest of the three.
  SMS_CONSENT_SOURCES = %w[contractor_portal dealer_recorded import].freeze

  # ----- Validations -----
  validates :sms_consent_source, inclusion: { in: SMS_CONSENT_SOURCES }, allow_blank: true
  validates :name, presence: true, length: { maximum: 255 }
  validates :vendor_type, inclusion: { in: VENDOR_TYPES }, allow_blank: true
  validates :status,      inclusion: { in: STATUSES },     allow_blank: true
  validates :trade_type,  inclusion: { in: TRADE_TYPES },  allow_blank: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :phone, length: { maximum: 20 }, allow_blank: true
  validates :code, uniqueness: {
    scope: :company_id,
    conditions: -> { where(is_deleted: [false, nil]) },
    allow_nil: true
  }, allow_blank: true

  # ----- Scopes -----
  scope :active,           -> { where(status: 'active', is_deleted: [false, nil]) }
  scope :not_deleted,      -> { where(is_deleted: [false, nil]) }
  scope :by_trade,         ->(trade) { where(trade_type: trade) }
  scope :only_contractors, -> { where(vendor_type: 'contractor') }
  scope :only_suppliers,   -> { where(vendor_type: 'supplier') }
  scope :eligible_1099,    -> { where(is_1099_eligible: true) }
  scope :for_company,      ->(company_id) { where(company_id: company_id, is_deleted: [false, nil]) }
  scope :by_name,          -> { order(:name) }

  before_validation :normalize_fields

  # ----- Portal authentication (was on Contractor) -----
  def generate_portal_token!
    update!(
      portal_access_token: SecureRandom.random_number(100000..999999).to_s,
      portal_token_expires_at: 30.minutes.from_now
    )
  end

  def portal_token_valid?(token)
    portal_access_token == token && portal_token_expires_at&.future?
  end

  # High-entropy token behind the one-click link in an assignment email.
  #
  # Long-lived on purpose: an assignment notice is routinely opened the next
  # morning, and a 30-minute window would strand the contractor exactly like the
  # code they never received. It can afford the longer life because it is 32
  # random bytes rather than 6 digits, and it is matched with a constant-time
  # comparison.
  def generate_portal_link_token!(expires_in: 7.days)
    update!(
      portal_link_token: SecureRandom.urlsafe_base64(32),
      portal_link_expires_at: expires_in.from_now
    )
    portal_link_token
  end

  def portal_link_valid?(token)
    portal_link_token.present? && token.present? &&
      ActiveSupport::SecurityUtils.secure_compare(portal_link_token, token.to_s) &&
      portal_link_expires_at&.future?
  end

  def consume_portal_link_token!
    update!(portal_link_token: nil, portal_link_expires_at: nil)
  end

  def can_login_with_password?
    password_login_enabled? && password_digest.present?
  end

  # ----- Soft delete (was on Supplier) -----
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, active: false, status: 'inactive')
  end

  def restore!
    update!(is_deleted: false, deleted_at: nil, active: true, status: 'active')
  end

  # ----- Display -----
  def display_name
    code.present? ? "#{name} (#{code})" : name
  end

  def full_address
    parts = [address_line1, address_line2, city, state, zip_code, country].compact.reject(&:blank?)
    parts.any? ? parts.join(', ') : nil
  end

  def contractor?
    vendor_type == 'contractor'
  end

  def supplier?
    vendor_type == 'supplier'
  end

  # Set SMS consent along with the provenance that makes it defensible.
  # Granting requires a source; revoking never does, because a contractor must
  # always be able to stop texts without anyone justifying it.
  #
  # @param opted_in [Boolean]
  # @param source [String] one of SMS_CONSENT_SOURCES (required when granting)
  # @param user [User, nil] who recorded it (nil when the contractor did it themselves)
  # @param note [String, nil] how consent was obtained
  def record_sms_consent!(opted_in:, source: nil, user: nil, note: nil)
    if opted_in
      raise ArgumentError, 'source is required to grant SMS consent' if source.blank?

      update!(
        sms_opt_in: true,
        sms_consent_source: source,
        sms_consent_recorded_at: Time.current,
        sms_consent_recorded_by_id: user&.id,
        sms_consent_note: note.presence
      )
    else
      # Keep the prior source/note as the historical record of what was revoked.
      update!(sms_opt_in: false, sms_consent_recorded_at: Time.current,
              sms_consent_recorded_by_id: user&.id)
    end
  end

  # True when we hold a consent record good enough to text this contractor.
  def can_receive_sms?
    sms_opt_in? && phone.present?
  end

  def sms_consent_json
    {
      smsOptIn: !!sms_opt_in,
      canReceiveSms: can_receive_sms?,
      consentSource: sms_consent_source,
      consentRecordedAt: sms_consent_recorded_at,
      consentRecordedBy: sms_consent_recorded_by_id &&
        User.where(id: sms_consent_recorded_by_id).pick(:first_name, :last_name)&.compact&.join(' ').presence,
      consentNote: sms_consent_note
    }
  end

  private

  def normalize_fields
    self.name = name&.strip
    self.code = code&.strip&.upcase if code.present?
    self.email = email&.strip&.downcase if email.present?
    self.phone = phone&.strip if phone.present?
    self.city = city&.strip&.titleize if city.present?
    self.state = state&.strip&.upcase if state.present?
    self.zip_code = zip_code&.strip if zip_code.present?
    self.country = country&.strip&.upcase if country.present?
  end

  private

  def lost_portal_access?
    (saved_change_to_status? && status != 'active') ||
      (saved_change_to_is_deleted? && is_deleted == true)
  end

  def revoke_device_sessions_after_access_change
    DeviceSession.revoke_all_for(self, 'access_changed')
  rescue StandardError => e
    Rails.logger.error("[DeviceSession] Could not revoke for vendor #{id}: #{e.message}")
  end
end
