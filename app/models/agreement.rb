class Agreement < ApplicationRecord
  belongs_to :company
  belongs_to :agreement_template, optional: true
  belongs_to :location, optional: true
  belongs_to :prepared_by, class_name: 'User', optional: true
  belongs_to :voided_by, class_name: 'User', optional: true
  belongs_to :parent_agreement, class_name: 'Agreement', optional: true
  belongs_to :contact, optional: true
  belongs_to :account, optional: true
  belongs_to :deal, optional: true

  has_many :versions, class_name: 'Agreement', foreign_key: :parent_agreement_id, dependent: :nullify
  has_many :agreement_signers, dependent: :destroy
  has_many :agreement_attachments, dependent: :destroy
  has_many :agreement_audit_logs, dependent: :destroy
  has_many :agreement_reminders, dependent: :destroy

  # Validations
  validates :title, presence: true
  validates :agreement_number, uniqueness: { scope: :company_id }, allow_nil: true
  before_validation :generate_agreement_number, on: :create
  validates :status, presence: true, inclusion: {
    in: %w[draft sent viewed partially_signed completed expired voided declined]
  }
  validates :delivery_method, inclusion: { in: %w[email sms both] }, allow_nil: true
  validates :signing_order, inclusion: { in: %w[parallel sequential counter_sign] }, allow_nil: true

  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_category, ->(category) { where(category: category) if category.present? }
  scope :for_current_location, -> {
    Current.location_filtered? ? where(location_id: Current.location_id) : all
  }
  scope :for_entity, ->(type, id) {
    case type.to_s
    when 'Contact' then where(contact_id: id)
    when 'Account' then where(account_id: id)
    when 'Deal'    then where(deal_id: id)
    else none
    end
  }
  scope :for_contact, ->(id) { where(contact_id: id) }
  scope :for_account, ->(id) { where(account_id: id) }
  scope :for_deal, ->(id) { where(deal_id: id) }
  scope :expiring_soon, ->(days = 7) {
    where(status: %w[sent viewed partially_signed])
      .where('expires_at IS NOT NULL AND expires_at <= ?', days.days.from_now)
  }
  scope :expired_unprocessed, -> {
    where(status: %w[sent viewed partially_signed])
      .where('expires_at IS NOT NULL AND expires_at < ?', Time.current)
  }

  # Status constants
  STATUS_DRAFT = 'draft'
  STATUS_SENT = 'sent'
  STATUS_VIEWED = 'viewed'
  STATUS_PARTIALLY_SIGNED = 'partially_signed'
  STATUS_COMPLETED = 'completed'
  STATUS_EXPIRED = 'expired'
  STATUS_VOIDED = 'voided'
  STATUS_DECLINED = 'declined'

  # Callbacks
  after_save :trigger_webhooks, if: :saved_change_to_status?
  after_create :log_creation

  # === Status Transitions ===

  def send_to_signers!(user = nil)
    return false unless status == STATUS_DRAFT
    return false if agreement_signers.where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER]).empty?

    update!(status: STATUS_SENT, sent_at: Time.current)
    AgreementAuditLog.log!(self, AgreementAuditLog::ACTION_SENT, performed_by: user)
    true
  end

  def mark_viewed!(signer = nil)
    if status == STATUS_SENT
      update!(status: STATUS_VIEWED)
    end
  end

  def mark_partially_signed!
    if %w[sent viewed].include?(status)
      update!(status: STATUS_PARTIALLY_SIGNED)
    end
  end

  def complete!
    return false unless all_signed?

    update!(status: STATUS_COMPLETED, completed_at: Time.current)
    AgreementAuditLog.log!(self, AgreementAuditLog::ACTION_COMPLETED)

    # Use perform_now to ensure sealing happens immediately
    # (perform_later requires Solid Queue worker running)
    if defined?(SealAgreementJob)
      if Rails.env.production? || Rails.env.staging?
        SealAgreementJob.perform_later(id)
      else
        SealAgreementJob.perform_now(id)
      end
    end
    true
  end

  def void!(user, reason = nil)
    return false unless can_void?

    update!(
      status: STATUS_VOIDED,
      voided_at: Time.current,
      voided_by: user,
      void_reason: reason
    )
    AgreementAuditLog.log!(self, AgreementAuditLog::ACTION_VOIDED, performed_by: user, metadata: { reason: reason })
    true
  end

  def expire!
    return false unless %w[sent viewed partially_signed].include?(status)

    update!(status: STATUS_EXPIRED)
    AgreementAuditLog.log!(self, AgreementAuditLog::ACTION_EXPIRED)
    true
  end

  def decline!(signer)
    update!(status: STATUS_DECLINED, declined_at: Time.current)
    AgreementAuditLog.log!(self, AgreementAuditLog::ACTION_DECLINED, agreement_signer: signer)
  end

  # === Query Methods ===

  def can_void?
    %w[draft sent viewed partially_signed].include?(status)
  end

  def can_edit?
    status == STATUS_DRAFT
  end

  def can_send?
    status == STATUS_DRAFT && agreement_signers.where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER]).any?
  end

  def all_signed?
    required_signers = agreement_signers.where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER])
    required_signers.any? && required_signers.all? { |s| s.status == AgreementSigner::STATUS_SIGNED }
  end

  def pending_signers
    agreement_signers.where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER])
                     .where.not(status: AgreementSigner::STATUS_SIGNED)
  end

  def signing_progress
    required = agreement_signers.where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER])
    return { total: 0, signed: 0, percentage: 0 } if required.empty?

    signed = required.where(status: AgreementSigner::STATUS_SIGNED).count
    { total: required.count, signed: signed, percentage: ((signed.to_f / required.count) * 100).round }
  end

  def expired?
    expires_at.present? && expires_at < Time.current && %w[sent viewed partially_signed].include?(status)
  end

  def duplicate!(user = nil)
    new_agreement = dup
    new_agreement.agreement_number = nil # Will be auto-generated
    new_agreement.status = STATUS_DRAFT
    new_agreement.version = (parent_agreement || self).versions.maximum(:version).to_i + 1
    new_agreement.parent_agreement = parent_agreement || self
    new_agreement.prepared_by = user
    new_agreement.sent_at = nil
    new_agreement.completed_at = nil
    new_agreement.voided_at = nil
    new_agreement.declined_at = nil
    new_agreement.sealed_document_url = nil
    new_agreement.last_reminder_sent_at = nil
    new_agreement.expires_at = 30.days.from_now if expires_at.present?
    new_agreement.save!

    # Copy signers (without signatures)
    agreement_signers.each do |signer|
      new_signer = signer.dup
      new_signer.agreement = new_agreement
      new_signer.status = AgreementSigner::STATUS_PENDING
      new_signer.access_token = nil # Will be auto-generated
      new_signer.signed_at = nil
      new_signer.viewed_at = nil
      new_signer.declined_at = nil
      new_signer.signature_url = nil
      new_signer.initials_url = nil
      new_signer.typed_signature = nil
      new_signer.typed_initials = nil
      new_signer.ip_address = nil
      new_signer.user_agent = nil
      new_signer.signature_hash = nil
      new_signer.save!
    end

    AgreementAuditLog.log!(new_agreement, AgreementAuditLog::ACTION_CREATED, performed_by: user, metadata: { source: 'duplicate', original_id: id })
    new_agreement
  end

  def snapshot_deal_equipment!
    return unless deal_id.present?

    deal = company.deals.find_by(id: deal_id)
    return unless deal

    line_items = deal.deal_line_items&.where(is_deleted: [false, nil])&.order(:position) || []

    snapshot = line_items.map do |item|
      {
        description: item.description || item.name,
        amount: item.price.to_f,
        cost: item.cost.to_f,
        taxable: item.taxable || false,
        category: item.category,
        quantity: item.quantity || 1,
        line_total: (item.price.to_f * (item.quantity || 1)).round(2)
      }
    end

    update_column(:optional_equipment_snapshot, snapshot)
    snapshot
  end

  def merge_custom_field_values!(new_values)
    return if new_values.blank?

    existing = custom_field_values || {}
    merged = existing.merge(new_values.stringify_keys)
    update_column(:custom_field_values, merged)
    merged
  end

  private

  def generate_agreement_number
    return if agreement_number.present?

    year = Time.current.year
    prefix = "AGR-#{year}-"

    last_number = company.agreements
      .where("agreement_number LIKE ?", "#{prefix}%")
      .order(agreement_number: :desc)
      .limit(1)
      .pluck(:agreement_number)
      .first

    if last_number
      sequence = last_number.gsub(prefix, '').to_i + 1
    else
      sequence = 1
    end

    self.agreement_number = "#{prefix}#{sequence.to_s.rjust(5, '0')}"
  end

  def trigger_webhooks
    return unless company.present?

    event = case status
    when STATUS_SENT then 'agreement.sent'
    when STATUS_VIEWED then 'agreement.viewed'
    when STATUS_COMPLETED then 'agreement.completed'
    when STATUS_VOIDED then 'agreement.voided'
    when STATUS_EXPIRED then 'agreement.expired'
    when STATUS_DECLINED then 'agreement.declined'
    else return
    end

    WebhookService.fire(
      company_id: company.id,
      event: event,
      payload: as_json(
        only: [:id, :title, :agreement_number, :status, :category, :sent_at, :completed_at, :expires_at],
        include: {
          agreement_signers: { only: [:id, :name, :email, :role, :status, :signed_at] }
        }
      )
    ) if defined?(WebhookService)
  rescue => e
    Rails.logger.error("[Agreement] Webhook trigger failed: #{e.message}")
  end

  def log_creation
    AgreementAuditLog.log!(self, AgreementAuditLog::ACTION_CREATED, performed_by: prepared_by)
  end
end
