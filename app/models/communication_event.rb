# == Schema Information
#
# Table name: communication_events
#
#  id                 :bigint           not null, primary key
#  communication_id   :bigint           not null
#  event_type         :string           not null (sent, delivered, opened, clicked, bounced, failed, unsubscribed)
#  occurred_at        :datetime         not null
#  ip_address         :string
#  user_agent         :string
#  details            :jsonb
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# Indexes
#
#  index_communication_events_on_communication_id  (communication_id)
#  index_communication_events_on_event_type        (event_type)
#  index_communication_events_on_occurred_at       (occurred_at)
#

class CommunicationEvent < ApplicationRecord
  # SQLite compatibility
  serialize :details, coder: JSON
  belongs_to :communication
  
  # Validations
  validates :event_type, presence: true, inclusion: { 
    in: %w[sent delivered opened clicked bounced failed unsubscribed spam_report]
  }
  validates :occurred_at, presence: true
  
  # Scopes
  scope :sent, -> { where(event_type: 'sent') }
  scope :delivered, -> { where(event_type: 'delivered') }
  scope :opened, -> { where(event_type: 'opened') }
  scope :clicked, -> { where(event_type: 'clicked') }
  scope :bounced, -> { where(event_type: 'bounced') }
  scope :failed, -> { where(event_type: 'failed') }
  scope :unsubscribed, -> { where(event_type: 'unsubscribed') }
  scope :recent, -> { order(occurred_at: :desc) }
  scope :by_type, ->(type) { where(event_type: type) }
  
  # Callbacks
  after_create :update_communication_status
  
  # Class methods
  def self.track(communication:, event_type:, details: {}, ip_address: nil, user_agent: nil)
    create!(
      communication: communication,
      event_type: event_type,
      occurred_at: Time.current,
      ip_address: ip_address,
      user_agent: user_agent,
      details: details
    )
  end
  
  def self.track_send(communication, details = {})
    track(communication: communication, event_type: 'sent', details: details)
  end
  
  def self.track_delivery(communication, details = {})
    track(communication: communication, event_type: 'delivered', details: details)
  end
  
  def self.track_open(communication, ip_address: nil, user_agent: nil)
    track(
      communication: communication,
      event_type: 'opened',
      ip_address: ip_address,
      user_agent: user_agent
    )
  end
  
  def self.track_click(communication, url:, ip_address: nil, user_agent: nil)
    track(
      communication: communication,
      event_type: 'clicked',
      details: { url: url },
      ip_address: ip_address,
      user_agent: user_agent
    )
  end
  
  def self.track_bounce(communication, reason:, details: {})
    track(
      communication: communication,
      event_type: 'bounced',
      details: details.merge(reason: reason)
    )
  end
  
  def self.track_failure(communication, error:, details: {})
    track(
      communication: communication,
      event_type: 'failed',
      details: details.merge(error: error.to_s)
    )
  end
  
  def self.track_unsubscribe(communication, ip_address: nil, user_agent: nil)
    track(
      communication: communication,
      event_type: 'unsubscribed',
      ip_address: ip_address,
      user_agent: user_agent
    )
  end
  
  # Instance methods
  def sent?
    event_type == 'sent'
  end
  
  def delivered?
    event_type == 'delivered'
  end
  
  def opened?
    event_type == 'opened'
  end
  
  def clicked?
    event_type == 'clicked'
  end
  
  def bounced?
    event_type == 'bounced'
  end
  
  def failed?
    event_type == 'failed'
  end
  
  def clicked_url
    details&.dig('url')
  end
  
  def bounce_reason
    details&.dig('reason')
  end
  
  def error_message
    details&.dig('error')
  end
  
  def add_detail(key, value)
    self.details ||= {}
    self.details[key.to_s] = value
    save
  end
  
  private
  
  def update_communication_status
    case event_type
    when 'sent'
      communication.mark_as_sent! unless communication.sent?
    when 'delivered'
      communication.mark_as_delivered! unless communication.delivered?
    when 'bounced'
      communication.mark_as_bounced! unless communication.status == 'bounced'
    when 'failed'
      error = details&.dig('error') || 'Unknown error'
      communication.mark_as_failed!(error) unless communication.failed?
    end
  rescue => e
    # Log error but don't fail event creation
    Rails.logger.error("Failed to update communication status: #{e.message}")
  end
end
