# == Schema Information
#
# Table name: communications
#
#  id                    :bigint           not null, primary key
#  communicable_type     :string           not null
#  communicable_id       :bigint           not null
#  communication_thread_id :bigint
#  direction             :string           not null (outbound, inbound)
#  channel               :string           not null (email, sms, portal_message)
#  provider              :string           (smtp, gmail_relay, aws_ses, twilio)
#  status                :string           not null (pending, sent, delivered, failed, bounced)
#  subject               :string
#  body                  :text
#  from_address          :string
#  to_address            :string
#  cc_addresses          :text
#  bcc_addresses         :text
#  reply_to              :string
#  portal_visible        :boolean          default(false)
#  sent_at               :datetime
#  delivered_at          :datetime
#  failed_at             :datetime
#  error_message         :text
#  metadata              :jsonb
#  external_id           :string           (provider message ID)
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_communications_on_communicable               (communicable_type, communicable_id)
#  index_communications_on_communication_thread_id    (communication_thread_id)
#  index_communications_on_channel                    (channel)
#  index_communications_on_status                     (status)
#  index_communications_on_external_id                (external_id)
#  index_communications_on_created_at                 (created_at)
#

class Communication < ApplicationRecord
  # SQLite compatibility
  serialize :metadata, coder: JSON
  # Polymorphic association - can belong to Lead, Account, Quote, etc.
  belongs_to :communicable, polymorphic: true
  belongs_to :communication_thread, optional: true
  
  has_many :communication_events, dependent: :destroy
  
  # Validations
  validates :direction, presence: true, inclusion: { in: %w[outbound inbound] }
  validates :channel, presence: true, inclusion: { in: %w[email sms portal_message] }
  validates :status, presence: true, inclusion: { in: %w[pending sent delivered failed bounced] }
  validates :body, presence: true
  
  validate :validate_channel_requirements
  
  # Scopes
  scope :outbound, -> { where(direction: 'outbound') }
  scope :inbound, -> { where(direction: 'inbound') }
  scope :email, -> { where(channel: 'email') }
  scope :sms, -> { where(channel: 'sms') }
  scope :portal_visible, -> { where(portal_visible: true) }
  scope :sent, -> { where(status: 'sent') }
  scope :delivered, -> { where(status: 'delivered') }
  scope :failed, -> { where(status: 'failed') }
  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_thread, ->(thread_id) { where(communication_thread_id: thread_id) }
  
  # Thread management
  before_create :assign_to_thread
  after_create :update_thread_timestamp
  
  # Status transitions
  def mark_as_sent!
    update!(status: 'sent', sent_at: Time.current)
  end
  
  def mark_as_delivered!
    update!(status: 'delivered', delivered_at: Time.current)
  end
  
  def mark_as_failed!(error)
    update!(
      status: 'failed',
      failed_at: Time.current,
      error_message: error.to_s
    )
  end
  
  def mark_as_bounced!
    update!(status: 'bounced', failed_at: Time.current)
  end
  
  # Channel checks
  def email?
    channel == 'email'
  end
  
  def sms?
    channel == 'sms'
  end
  
  def portal_message?
    channel == 'portal_message'
  end
  
  def outbound?
    direction == 'outbound'
  end
  
  def inbound?
    direction == 'inbound'
  end
  
  # Metadata helpers
  def add_metadata(key, value)
    self.metadata ||= {}
    self.metadata[key.to_s] = value
    save
  end
  
  def get_metadata(key)
    metadata&.dig(key.to_s)
  end
  
  # Tracking
  def track_event(event_type, details = {})
    communication_events.create!(
      event_type: event_type,
      occurred_at: Time.current,
      details: details
    )
  end
  
  def opened?
    communication_events.where(event_type: 'opened').exists?
  end
  
  def clicked?
    communication_events.where(event_type: 'clicked').exists?
  end
  
  private
  
  def validate_channel_requirements
    case channel
    when 'email'
      errors.add(:subject, "can't be blank for email") if subject.blank?
      errors.add(:to_address, "can't be blank for email") if to_address.blank?
      errors.add(:from_address, "can't be blank for email") if from_address.blank?
    when 'sms'
      errors.add(:to_address, "can't be blank for SMS") if to_address.blank?
      errors.add(:from_address, "can't be blank for SMS") if from_address.blank?
    end
  end
  
  def assign_to_thread
    return if communication_thread_id.present?
    
    # Find or create thread for this communicable entity
    thread = CommunicationThread.find_or_create_for(
      communicable_type: communicable_type,
      communicable_id: communicable_id,
      channel: channel
    )
    
    self.communication_thread_id = thread.id
  end
  
  def update_thread_timestamp
    communication_thread&.touch(:last_message_at)
  end

  public

# Status query methods
def sent?
  status == 'sent'
end

def delivered?
  status == 'delivered'
end

def failed?
  status == 'failed'
end

def opened?
  opened_at.present?
end

end