# app/models/notification_preference.rb
class NotificationPreference < ApplicationRecord
  belongs_to :user
  
  # Validations
  validates :notification_type, presence: true, uniqueness: { scope: :user_id }
  validates :category, presence: true
  validates :frequency, inclusion: { in: %w[immediate daily weekly disabled] }
  
  # Scopes
  scope :by_category, ->(category) { where(category: category) }
  scope :enabled_for_channel, ->(channel) { where("#{channel}_enabled": true) }
  
  # Default settings for each notification type
  # High priority notifications have email enabled by default
  DEFAULT_SETTINGS = {
    # Service notifications
    service_ticket_assigned: { in_app: true, email: true, sms: false },
    service_ticket_updated: { in_app: true, email: false, sms: false },
    service_ticket_completed: { in_app: true, email: false, sms: false },
    
    # CRM notifications
    lead_assigned: { in_app: true, email: true, sms: false },
    contact_updated: { in_app: true, email: false, sms: false },
    task_assigned: { in_app: true, email: true, sms: false },
    task_due_soon: { in_app: true, email: true, sms: false },
    
    # Sales notifications
    quote_accepted: { in_app: true, email: true, sms: false },
    quote_rejected: { in_app: true, email: false, sms: false },
    deal_stage_changed: { in_app: true, email: false, sms: false },
    deal_won: { in_app: true, email: true, sms: false },
    deal_lost: { in_app: true, email: false, sms: false },
    
    # Finance notifications
    payment_received: { in_app: true, email: false, sms: false },
    payment_failed: { in_app: true, email: true, sms: false },
    invoice_sent: { in_app: true, email: false, sms: false },
    invoice_overdue: { in_app: true, email: true, sms: false },
    
    # System notifications
    message_received: { in_app: true, email: false, sms: false },
    mention_received: { in_app: true, email: true, sms: false },
    approval_required: { in_app: true, email: true, sms: false },
    approval_completed: { in_app: true, email: false, sms: false },
    
    # Broadcast notifications
    broadcast_message: { in_app: true, email: false, sms: false },
    system_alert: { in_app: true, email: true, sms: false }
  }.freeze
  
  # Get or create preference for user and notification type
  def self.get_or_create_for(user, notification_type)
    type_config = Notification::TYPES[notification_type.to_sym]
    return nil unless type_config
    
    find_or_create_by!(
      user: user,
      notification_type: notification_type.to_s
    ) do |pref|
      defaults = DEFAULT_SETTINGS[notification_type.to_sym] || { in_app: true, email: false, sms: false }
      pref.category = type_config[:category]
      pref.in_app_enabled = defaults[:in_app]
      pref.email_enabled = defaults[:email]
      pref.sms_enabled = defaults[:sms]
      pref.frequency = 'immediate'
    end
  end
  
  # Check if delivery should happen based on quiet hours
  def should_deliver_now?
    return true unless respect_quiet_hours
    return true if quiet_hours_start.blank? || quiet_hours_end.blank?
    
    current_time = Time.current.in_time_zone(user.time_zone || 'America/Denver')
    current_time_of_day = current_time.seconds_since_midnight
    
    start_seconds = quiet_hours_start.seconds_since_midnight
    end_seconds = quiet_hours_end.seconds_since_midnight
    
    if start_seconds < end_seconds
      # Normal case: quiet hours don't span midnight
      !(current_time_of_day >= start_seconds && current_time_of_day < end_seconds)
    else
      # Quiet hours span midnight
      !(current_time_of_day >= start_seconds || current_time_of_day < end_seconds)
    end
  end
end
