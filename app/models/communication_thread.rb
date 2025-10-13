# == Schema Information
#
# Table name: communication_threads
#
#  id                :bigint           not null, primary key
#  subject           :string
#  channel           :string           not null
#  status            :string           default('active')
#  last_message_at   :datetime
#  metadata          :jsonb
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_communication_threads_on_channel          (channel)
#  index_communication_threads_on_status           (status)
#  index_communication_threads_on_last_message_at  (last_message_at)
#

class CommunicationThread < ApplicationRecord
  # SQLite compatibility
  serialize :metadata, coder: JSON
  has_many :communications, dependent: :nullify
  
  # Validations
  validates :channel, presence: true, inclusion: { in: %w[email sms portal_message] }
  validates :status, presence: true, inclusion: { in: %w[active archived closed] }
  
  # Scopes
  scope :active, -> { where(status: 'active') }
  scope :archived, -> { where(status: 'archived') }
  scope :closed, -> { where(status: 'closed') }
  scope :recent, -> { order(last_message_at: :desc) }
  scope :by_channel, ->(channel) { where(channel: channel) }
  
  # Class methods
  def self.find_or_create_for(communicable_type:, communicable_id:, channel:, subject: nil)
    # Find existing active thread for this entity and channel
    thread = joins(:communications)
      .where(
        communications: {
          communicable_type: communicable_type,
          communicable_id: communicable_id
        },
        channel: channel,
        status: 'active'
      )
      .order(last_message_at: :desc)
      .first
    
    # Create new thread if none exists
    thread ||= create!(
      channel: channel,
      subject: subject,
      status: 'active',
      last_message_at: Time.current
    )
    
    thread
  end
  
  # Instance methods
  def last_communication
    communications.order(created_at: :desc).first
  end
  
  def first_communication
    communications.order(created_at: :asc).first
  end
  
  def message_count
    communications.count
  end
  
  def participants
    # Get unique communicable entities involved in this thread
    communications.pluck(:communicable_type, :communicable_id).uniq
  end
  
  def archive!
    update!(status: 'archived')
  end
  
  def close!
    update!(status: 'closed')
  end
  
  def reopen!
    update!(status: 'active')
  end
  
  def add_metadata(key, value)
    self.metadata ||= {}
    self.metadata[key.to_s] = value
    save
  end
  
  def get_metadata(key)
    metadata&.dig(key.to_s)
  end
  
  # Email-specific helpers
  def email_thread_id
    get_metadata('email_thread_id')
  end
  
  def set_email_thread_id(thread_id)
    add_metadata('email_thread_id', thread_id)
  end
  
  # Summary stats
  def stats
    {
      total_messages: message_count,
      outbound_count: communications.outbound.count,
      inbound_count: communications.inbound.count,
      last_message_at: last_message_at,
      opened_count: communications.joins(:communication_events)
        .where(communication_events: { event_type: 'opened' }).count,
      clicked_count: communications.joins(:communication_events)
        .where(communication_events: { event_type: 'clicked' }).count
    }
  end
end
