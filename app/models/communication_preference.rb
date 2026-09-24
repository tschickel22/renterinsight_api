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
  after_save :mirror_sms_marketing_consent
  
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
  
# Marketing consent is the one category where silence is NOT permission.
#
# can_send_to? below treats a missing preference as opted in, which is right for
# transactional mail: somebody who asked a salesperson for a quote should get the
# quote. Applying that default to marketing turns the whole system into
# opt-out-by-default, which is the model this gate exists to prevent. Here an
# absent record means nobody ever asked, so the answer is no.
def self.marketing_consent?(recipient:, channel: 'email')
  return false if recipient.nil?

  where(recipient: recipient, channel: channel, category: 'marketing')
    .where(opted_in: true)
    .exists?
end

def self.can_send_to?(recipient:, channel:, category: nil)
  preference = where(
    recipient: recipient,
    channel: channel,
    category: category
  ).first
  
  # If no preference exists, default to opted in
  return true if preference.nil?
  
  # If preference exists, check if opted in
  preference.opted_in?
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

  private

  # Keep opt_in_sms in step with marketing consent for the SMS channel.
  #
  # These were two disconnected permissions gating the same send. The audience
  # filter (CampaignAudience#scope_for_sms_compliance, AudienceEnroller) selects
  # on the opt_in_sms COLUMN, while CampaignSender gates on this PREFERENCE, so
  # an SMS campaign recipient had to satisfy both. Someone who ticked the
  # consent box on a lead form got the preference and not the column, and was
  # filtered out of the audience before the gate ever saw them. Someone whose
  # form mapped a field to opt_in_sms got the column and not the preference, and
  # was skipped at send time instead. Either way the dealer saw a smaller send
  # than they built and no reason for it.
  #
  # The column is the one the audience filter reads, so it follows the
  # preference. Only marketing/sms writes here: a transactional preference says
  # nothing about marketing permission.
  def mirror_sms_marketing_consent
    return unless channel == 'sms' && category == 'marketing'
    return unless recipient.respond_to?(:opt_in_sms) && recipient.class.column_names.include?('opt_in_sms')
    return if recipient.opt_in_sms == opted_in

    recipient.update_column(:opt_in_sms, opted_in)
  rescue StandardError => e
    # A preference that saved is the record of consent; the column is a
    # denormalised copy for the audience filter. Losing the copy must not lose
    # the consent.
    Rails.logger.warn(
      "[CommunicationPreference##{id}] could not mirror opt_in_sms to " \
      "#{recipient_type}##{recipient_id}: #{e.message}"
    )
  end
end
