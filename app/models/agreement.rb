class Agreement < ApplicationRecord
  # Confidential files: stored as references, served as expiring links (PrivateFiles).
  include PrivateFileColumns
  private_file_columns :document_url, :sealed_document_url
  private_file_lists :document_urls

  include ActivityTrackable

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
  before_validation :normalize_content_type
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
    case type.to_s.capitalize
    when 'Contact' then where(contact_id: id)
    when 'Account'
      # Rollup: include agreements directly on the account OR on any of the account's contacts
      contact_ids = Contact.where(account_id: id, is_deleted: [false, nil]).select(:id)
      where(account_id: id).or(where(contact_id: contact_ids))
    when 'Deal' then where(deal_id: id)
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

    # Clear any stale sealed document from previous signing rounds
    update!(status: STATUS_SENT, sent_at: Time.current, sealed_document_url: nil)
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

    # Seal the signed PDF: async in production/staging, sync in dev/test
    if Rails.env.production? || Rails.env.staging?
      SealAgreementJob.perform_later(id)
    else
      SealAgreementJob.perform_now(id)
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
    status == STATUS_DRAFT &&
      agreement_signers.where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER]).any? &&
      !has_unsigned_preparer_fields?
  end

  def has_unsigned_preparer_fields?
    placements = (merge_field_placements || field_placements || []).map(&:stringify_keys)
    preparer_sig_fields = placements.select do |p|
      p['isCustomField'] == true &&
        !p['isSignerField'] &&
        %w[signature initials].include?((p['fieldType'] || p['field_type']).to_s.downcase)
    end
    return false if preparer_sig_fields.empty?

    values = (custom_field_values || {}).stringify_keys
    preparer_sig_fields.any? do |p|
      key = p['fieldKey'] || p['field_key']
      stripped_key = key&.sub(/^custom\./, '')
      val = values[key] || values[stripped_key]
      val.blank? || !val.to_s.start_with?('data:image/')
    end
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

  # Snapshots the deal's line items onto this agreement so they're preserved even if
  # the underlying deal changes later. Reads from the selected deal_desk_scenario's
  # line_items JSONB (falling back to deal_products for legacy deals). See
  # Agreements::DealLineItemsResolver for the priority order and shape.
  def snapshot_deal_equipment!
    return unless deal_id.present?

    deal = company.deals.find_by(id: deal_id)
    return unless deal

    snapshot = Agreements::DealLineItemsResolver.call(deal)

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

  # Copy field definitions from the linked template (if not already set)
  # The Deal Sheet version an agreement was made from (the LIVE one then), as
  # a fingerprint of its lines and contract total, so the agreement can say
  # when the LIVE sheet has moved on since. Repricing that changes nothing
  # does not count.
  def self.deal_sheet_stamp(build)
    return nil unless build

    lines = build.lines.map { |l| [l.kind, l.label, l.quantity.to_s, l.retail.to_s, l.tbd, l.no_charge] }
    { 'build_id' => build.id, 'version_number' => build.version_number, 'version_name' => build.version_name,
      'contract_total' => build.totals.to_h['contract_total'], 'digest' => Digest::SHA256.hexdigest([lines, build.totals.to_h['contract_total']].to_json)[0, 16] }
  end

  def stamp_deal_sheet!
    return unless deal

    stamp = self.class.deal_sheet_stamp(deal.home_build)
    self.metadata = metadata.to_h.merge('deal_sheet' => stamp) if stamp
  end

  # => { version_name, live, changed, live_version_name } or nil
  def deal_sheet_status
    stamp = metadata.to_h['deal_sheet']
    return nil unless stamp

    live = deal&.home_build
    current = self.class.deal_sheet_stamp(live)
    { version_name: stamp['version_name'], version_number: stamp['version_number'],
      live: live.present? && live.id == stamp['build_id'],
      changed: current.present? && (current['build_id'] != stamp['build_id'] || current['digest'] != stamp['digest']),
      live_version_name: live&.version_name }
  end

  def initialize_field_definitions_from_template!
    return unless agreement_template_id.present?
    return if custom_field_definitions.present?

    template = agreement_template
    return unless template&.custom_field_definitions.present?

    update_column(:custom_field_definitions, template.custom_field_definitions)
  end

  # ActivityTrackable overrides
  def activity_display_name
    title || agreement_number || 'Agreement'
  end

  def activity_module_name
    'finance'
  end

  def activity_account_id
    account_id || deal&.try(:account_id) || contact&.try(:account_id)
  end

  private

  # An agreement is pdf_upload or rich_text; a template's words are upload
  # and editor, and copying those across made the builder open a PDF
  # agreement in the text editor, whose autosave then turned it into text.
  # upload means a PDF when there is one (the column defaults to it).
  def normalize_content_type
    return if content_type == 'pdf_upload'

    # rich_text with no text but a PDF is a PDF agreement the builder's
    # editor autosaved: it stays a PDF.
    pdf = read_attribute(:document_url).present? || Array(read_attribute(:document_urls)).any?
    self.content_type = if pdf && content.blank? then 'pdf_upload'
                        elsif %w[rich_text editor html].include?(content_type) || content.present? then 'rich_text'
                        elsif pdf then 'pdf_upload'
                        else agreement_template&.agreement_content_type || 'pdf_upload'
                        end
  end

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
