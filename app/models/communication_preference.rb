# == Schema Information
#
# Table name: communication_preferences
#
#  id                    :bigint           not null, primary key
#  recipient_type        :string           not null (Lead, Account, User)
#  recipient_id          :bigint           not null
#  channel               :string           not null (email, sms, portal_message)
#  category              :string           (marketing, transactional, quotes, invoices, notifications)
#  opted_in              :boolean          default(true)
#  opted_in_at           :datetime
#  opted_out_at          :datetime
#  unsubscribe_token     :string
#  opted_out_reason      :text
#  ip_address            :string
#  user_agent            :string
#  compliance_metadata   :text             (stored as JSON)
#  created_at            :datetime         not null
#  updated_at            :datetime         not null

class CommunicationPreference < ApplicationRecord
  # SQLite compatibility - serialize JSON fields
  serialize :compliance_metadata, coder: JSON
  
  # Polymorphic association - can belong to Lead, Account, User
  belongs_to :recipient, polymorphic: true
  
  # Validations
  validates :channel, presence: true, inclusion: { in: %w[email sms portal_message] }
  validates :category, inclusion: { 
    in: %w[marketing transactional quotes invoices notifications], 
    allow_nil: true 
  }
  validates :unsubscribe_token, uniqueness: true, allow_nil: true
  
  # Callbacks
  before_create :generate_unsubscribe_token
  before_save :track_opt_change
  
  # Scopes
  scope :opted_in, -> { where(opted_in: true) }
  scope :opted_out, -> { where(opted_in: false) }
  scope :by_channel, ->(channel) { where(channel: channel) }
  scope :by_category, ->(category) { where(category: category) }
  scope :email, -> { where(channel: 'email') }
  scope :sms, -> { where(channel: 'sms') }
  
  # Class methods
  def self.find_or_create_for(recipient:, channel:, category: nil)
    find_or_create_by!(
      recipient: recipient,
      channel: channel,
      category: category
    )
  end
  
  def self.can_send_to?(recipient:, channel:, category: nil)
    preference = where(
      recipient: recipient,
      channel: channel,
      category: category
    ).first
    
    # If no preference exists, default to opted in for transactional
    return true if preference.nil? && category == 'transactional'
    return true if preference.nil? && category.nil?
    
    preference&.opted_in?
  end
  
  def self.by_token(token)
    find_by(unsubscribe_token: token)
  end
  
  # Instance methods
  def opt_in!(details = {})
    update!(
      opted_in: true,
      opted_in_at: Time.current,
      opted_out_at: nil,
      opted_out_reason: nil,
      ip_address: details[:ip_address],
      user_agent: details[:user_agent]
    )
    
    add_compliance_record('opted_in', details)
  end
  
  def opt_out!(reason = nil, details = {})
    update!(
      opted_in: false,
      opted_out_at: Time.current,
      opted_out_reason: reason,
      ip_address: details[:ip_address],
      user_agent: details[:user_agent]
    )
    
    add_compliance_record('opted_out', details.merge(reason: reason))
  end
  
  def opted_in?
    opted_in == true
  end
  
  def opted_out?
    !opted_in?
  end
  
  def unsubscribe_url(base_url)
    "#{base_url}/unsubscribe/#{unsubscribe_token}"
  end
  
  def add_compliance_record(action, details = {})
    self.compliance_metadata ||= { 'records' => [] }
    self.compliance_metadata['records'] ||= []
    
    self.compliance_metadata['records'] << {
      'action' => action,
      'timestamp' => Time.current.iso8601,
      'ip_address' => details[:ip_address],
      'user_agent' => details[:user_agent],
      'details' => details.except(:ip_address, :user_agent)
    }
    
    save
  end
  
  def compliance_history
    compliance_metadata&.dig('records') || []
  end
  
  # Category helpers
  def marketing?
    category == 'marketing'
  end
  
  def transactional?
    category == 'transactional'
  end
  
  def can_send?
    # Transactional messages can always be sent
    return true if transactional?
    
    # Otherwise check opt-in status
    opted_in?
  end
  
  private
  
  def generate_unsubscribe_token
    return if unsubscribe_token.present?
    
    loop do
      token = SecureRandom.urlsafe_base64(32)
      break self.unsubscribe_token = token unless self.class.exists?(unsubscribe_token: token)
    end
  end
  
  def track_opt_change
    if opted_in_changed? && opted_in?
      self.opted_in_at = Time.current
      self.opted_out_at = nil
      self.opted_out_reason = nil
    elsif opted_in_changed? && !opted_in?
      self.opted_out_at = Time.current
    end
  end
end
