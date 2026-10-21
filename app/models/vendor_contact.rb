# frozen_string_literal: true

# A person at a vendor. See CreateVendorContacts for why these exist.
class VendorContact < ApplicationRecord
  belongs_to :company
  belongs_to :vendor

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :phone, length: { maximum: 20 }, allow_blank: true
  validates :sms_consent_source, inclusion: { in: Vendor::SMS_CONSENT_SOURCES }, allow_blank: true
  validate :has_a_name_or_a_way_to_reach

  scope :not_deleted, -> { where(is_deleted: false) }
  scope :project_recipients, -> { not_deleted.where(receives_project_notices: true) }

  before_validation :normalize_fields
  before_validation -> { self.company_id ||= vendor&.company_id }
  after_save :keep_one_primary, if: -> { saved_change_to_is_primary? && is_primary? }

  def name
    [first_name, last_name].compact_blank.join(' ').presence
  end

  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, is_primary: false, receives_project_notices: false)
  end

  # Same rules as Vendor#record_sms_consent!: granting needs a source, revoking
  # never needs a reason.
  def record_sms_consent!(opted_in:, source: nil, user: nil, note: nil, recorded_at: Time.current)
    if opted_in
      raise ArgumentError, 'source is required to grant SMS consent' if source.blank?

      update!(sms_opt_in: true, sms_consent_source: source, sms_consent_recorded_at: recorded_at,
              sms_consent_recorded_by_id: user&.id, sms_consent_note: note.presence)
    else
      update!(sms_opt_in: false, sms_consent_recorded_at: recorded_at, sms_consent_recorded_by_id: user&.id)
    end
  end

  def can_receive_sms?
    sms_opt_in? && phone.present?
  end

  private

  def has_a_name_or_a_way_to_reach
    return if name.present? || email.present? || phone.present?

    errors.add(:base, 'Add a name, email or phone')
  end

  def normalize_fields
    self.first_name = first_name&.strip
    self.last_name = last_name&.strip
    self.email = email.strip.downcase if email.present?
    self.phone = phone.strip if phone.present?
  end

  def keep_one_primary
    vendor.vendor_contacts.where.not(id: id).where(is_primary: true).update_all(is_primary: false, updated_at: Time.current)
  end
end
