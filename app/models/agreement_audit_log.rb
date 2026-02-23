class AgreementAuditLog < ApplicationRecord
  belongs_to :agreement
  belongs_to :agreement_signer, optional: true
  belongs_to :performed_by, polymorphic: true, optional: true

  validates :action, presence: true

  # Action constants
  ACTION_CREATED = 'created'
  ACTION_SENT = 'sent'
  ACTION_VIEWED = 'viewed'
  ACTION_SIGNED = 'signed'
  ACTION_DECLINED = 'declined'
  ACTION_VOIDED = 'voided'
  ACTION_COMPLETED = 'completed'
  ACTION_REMINDER_SENT = 'reminder_sent'
  ACTION_EXPIRED = 'expired'
  ACTION_DOWNLOADED = 'downloaded'
  ACTION_SEALED = 'sealed'
  ACTION_PREPARED_SIGNATURE = 'prepared_signature'
  ACTION_FIELD_COMPLETED = 'field_completed'
  ACTION_ATTACHMENT_ADDED = 'attachment_added'
  ACTION_ATTACHMENT_REMOVED = 'attachment_removed'
  ACTION_SIGNER_ADDED = 'signer_added'
  ACTION_SIGNER_REMOVED = 'signer_removed'

  scope :for_agreement, ->(agreement_id) { where(agreement_id: agreement_id).order(created_at: :asc) }
  scope :by_action, ->(action) { where(action: action) if action.present? }

  def self.log!(agreement, action, opts = {})
    create!(
      agreement: agreement,
      agreement_signer: opts[:agreement_signer],
      action: action,
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent],
      geolocation: opts[:geolocation],
      performed_by: opts[:performed_by],
      metadata: opts[:metadata] || {}
    )
  rescue => e
    Rails.logger.error("[AgreementAuditLog] Failed to log #{action} for agreement #{agreement.id}: #{e.message}")
  end
end
