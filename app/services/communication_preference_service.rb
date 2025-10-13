# Service for managing communication preferences and compliance
#
# Usage:
#   CommunicationPreferenceService.opt_out(
#     recipient: lead,
#     channel: 'email',
#     category: 'marketing',
#     reason: 'Not interested',
#     ip_address: request.ip
#   )

class CommunicationPreferenceService
  class Error < StandardError; end
  
  # Check if we can send to a recipient
  def self.can_send_to?(recipient:, channel:, category: nil)
    CommunicationPreference.can_send_to?(
      recipient: recipient,
      channel: channel,
      category: category
    )
  end
  
  # Opt in to communications
  def self.opt_in(recipient:, channel:, category: nil, ip_address: nil, user_agent: nil)
    preference = CommunicationPreference.find_or_create_for(
      recipient: recipient,
      channel: channel,
      category: category
    )
    
    preference.opt_in!(
      ip_address: ip_address,
      user_agent: user_agent
    )
    
    preference
  end
  
  # Opt out of communications
  def self.opt_out(recipient:, channel:, category: nil, reason: nil, ip_address: nil, user_agent: nil)
    preference = CommunicationPreference.find_or_create_for(
      recipient: recipient,
      channel: channel,
      category: category
    )
    
    preference.opt_out!(
      reason,
      ip_address: ip_address,
      user_agent: user_agent
    )
    
    # Log opt-out event
    Rails.logger.info("Opt-out: #{recipient.class.name}##{recipient.id} from #{channel}/#{category}")
    
    preference
  end
  
  # Process unsubscribe via token
  def self.unsubscribe_by_token(token:, reason: nil, ip_address: nil, user_agent: nil)
    preference = CommunicationPreference.by_token(token)
    
    raise Error, "Invalid unsubscribe token" unless preference
    
    preference.opt_out!(
      reason || 'Unsubscribed via link',
      ip_address: ip_address,
      user_agent: user_agent
    )
    
    preference
  end
  
  # Get all preferences for a recipient
  def self.preferences_for(recipient:)
    CommunicationPreference.where(recipient: recipient)
  end
  
  # Get preference for specific channel/category
  def self.preference_for(recipient:, channel:, category: nil)
    CommunicationPreference.find_or_create_for(
      recipient: recipient,
      channel: channel,
      category: category
    )
  end
  
  # Bulk opt-out (for compliance requests)
  def self.opt_out_all(recipient:, reason: nil, ip_address: nil, user_agent: nil)
    preferences = CommunicationPreference.where(recipient: recipient)
    
    # Create preferences for all channels if they don't exist
    %w[email sms portal_message].each do |channel|
      %w[marketing transactional quotes invoices notifications].each do |category|
        next if category == 'transactional' # Can't opt out of transactional
        
        pref = CommunicationPreference.find_or_create_for(
          recipient: recipient,
          channel: channel,
          category: category
        )
        
        pref.opt_out!(
          reason || 'Bulk opt-out',
          ip_address: ip_address,
          user_agent: user_agent
        )
      end
    end
    
    preferences.reload
  end
  
  # Check if recipient is opted out of any communications
  def self.opted_out?(recipient:, channel: nil, category: nil)
    query = CommunicationPreference.where(recipient: recipient, opted_in: false)
    query = query.where(channel: channel) if channel
    query = query.where(category: category) if category
    
    query.exists?
  end
  
  # Get compliance report for recipient
  def self.compliance_report(recipient:)
    preferences = CommunicationPreference.where(recipient: recipient)
    
    {
      recipient_type: recipient.class.name,
      recipient_id: recipient.id,
      preferences: preferences.map do |pref|
        {
          channel: pref.channel,
          category: pref.category,
          opted_in: pref.opted_in,
          opted_in_at: pref.opted_in_at,
          opted_out_at: pref.opted_out_at,
          opted_out_reason: pref.opted_out_reason,
          compliance_history: pref.compliance_history
        }
      end,
      total_communications_sent: Communication.where(
        communicable: recipient,
        direction: 'outbound'
      ).count,
      generated_at: Time.current
    }
  end
  
  # Handle bounce - automatic opt-out for hard bounces
  def self.handle_bounce(communication:, bounce_type:, reason: nil)
    return unless bounce_type == 'hard'
    
    recipient = communication.communicable
    channel = communication.channel
    
    opt_out(
      recipient: recipient,
      channel: channel,
      reason: "Hard bounce: #{reason}",
      ip_address: nil,
      user_agent: 'System'
    )
    
    Rails.logger.warn(
      "Auto opt-out due to hard bounce: #{recipient.class.name}##{recipient.id} " \
      "on #{channel} - #{reason}"
    )
  end
  
  # Handle spam complaint
  def self.handle_spam_complaint(communication:)
    recipient = communication.communicable
    channel = communication.channel
    
    # Opt out of all marketing for this channel
    opt_out(
      recipient: recipient,
      channel: channel,
      category: 'marketing',
      reason: 'Spam complaint',
      ip_address: nil,
      user_agent: 'System'
    )
    
    Rails.logger.warn(
      "Opt-out due to spam complaint: #{recipient.class.name}##{recipient.id} on #{channel}"
    )
  end
  
  # Generate unsubscribe URL
  def self.unsubscribe_url(recipient:, channel:, category: nil, base_url: nil)
    preference = CommunicationPreference.find_or_create_for(
      recipient: recipient,
      channel: channel,
      category: category
    )
    
    base_url ||= ENV['APP_BASE_URL'] || 'https://app.platformdms.com'
    preference.unsubscribe_url(base_url)
  end
  
  # Add unsubscribe footer to email body
  def self.add_unsubscribe_footer(body:, unsubscribe_url:)
    footer = "\n\n---\n\nTo unsubscribe from these emails, click here: #{unsubscribe_url}"
    
    if body.include?('</body>')
      # HTML email
      html_footer = %{
        <div style="margin-top: 40px; padding-top: 20px; border-top: 1px solid #ccc; font-size: 12px; color: #666;">
          <p>To unsubscribe from these emails, <a href="#{unsubscribe_url}">click here</a>.</p>
        </div>
      }
      body.sub('</body>', "#{html_footer}</body>")
    else
      # Plain text email
      body + footer
    end
  end
end
