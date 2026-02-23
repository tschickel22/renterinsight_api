class AgreementReminder < ApplicationRecord
  belongs_to :agreement
  belongs_to :agreement_signer

  validates :scheduled_at, presence: true
  validates :reminder_type, presence: true, inclusion: { in: %w[auto manual] }
  validates :channel, presence: true, inclusion: { in: %w[email sms] }
  validates :status, presence: true, inclusion: { in: %w[pending sent failed] }

  scope :pending, -> { where(status: 'pending').where('scheduled_at <= ?', Time.current) }
  scope :upcoming, -> { where(status: 'pending').where('scheduled_at > ?', Time.current) }
  scope :sent, -> { where(status: 'sent') }
  scope :failed, -> { where(status: 'failed') }

  def mark_sent!
    update!(sent_at: Time.current, status: 'sent')
  end

  def mark_failed!(error = nil)
    update!(status: 'failed', error_message: error)
  end
end
