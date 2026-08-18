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

  # One place to enforce it rather than in each controller path that writes a
  # preference: a type outside PUSH_ELIGIBLE_TYPES can never be switched on for
  # push, whatever a bulk update or a category update sends.
  before_save :clear_push_for_ineligible_type
  
  # Default settings for each notification type
  # High priority notifications have email enabled by default
  #
  # `push` defaults to ON only for the handful of things worth a phone buzzing:
  # work newly landing on someone, a customer waiting on a reply, and an
  # explicit alarm. Anything else that is push-eligible ships off and is the
  # user's to switch on. A type absent from Notification::PUSH_ELIGIBLE_TYPES
  # cannot be pushed at all, whatever this says.
  DEFAULT_SETTINGS = {
    # Service notifications
    service_ticket_assigned: { in_app: true, email: true, sms: false, push: true },
    service_ticket_updated: { in_app: true, email: false, sms: false },
    service_ticket_completed: { in_app: true, email: false, sms: false },
    warranty_claim_assigned: { in_app: true, email: false, sms: false, push: false },

    # CRM notifications
    lead_assigned: { in_app: true, email: true, sms: false, push: true },
    contact_updated: { in_app: true, email: false, sms: false },
    task_assigned: { in_app: true, email: true, sms: false, push: true },
    task_due_soon: { in_app: true, email: true, sms: false, push: false },
    task_overdue: { in_app: true, email: true, sms: false, push: true },
    activity_reminder: { in_app: true, email: false, sms: false, push: true },

    # Sales notifications
    deal_assigned: { in_app: true, email: false, sms: false, push: false },
    quote_accepted: { in_app: true, email: true, sms: false, push: true },
    quote_rejected: { in_app: true, email: false, sms: false },
    deal_stage_changed: { in_app: true, email: false, sms: false },
    deal_won: { in_app: true, email: true, sms: false, push: true },
    deal_lost: { in_app: true, email: false, sms: false },
    home_sold_choose_new_home: { in_app: true, email: false, sms: false, push: false },

    # Finance notifications
    payment_received: { in_app: true, email: false, sms: false },
    payment_failed: { in_app: true, email: true, sms: false, push: true },
    invoice_sent: { in_app: true, email: false, sms: false },
    invoice_overdue: { in_app: true, email: true, sms: false, push: false },

    # System notifications
    message_received: { in_app: true, email: false, sms: false },
    mention_received: { in_app: true, email: true, sms: false, push: true },
    approval_required: { in_app: true, email: true, sms: false, push: true },
    approval_completed: { in_app: true, email: false, sms: false },

    # Broadcast notifications
    # Announcements land in the notification center; a company-wide push for
    # every one of them is exactly the spam we are trying to avoid.
    broadcast_message: { in_app: true, email: false, sms: false, push: false },
    system_alert: { in_app: true, email: true, sms: false, push: true },

    # Communications notifications
    sms_reply_received: { in_app: true, email: true, sms: false, push: true },
    email_reply_received: { in_app: true, email: false, sms: false, push: true },
    email_connection_broken: { in_app: true, email: true, sms: false, push: false },
    sms_cap_alert: { in_app: true, email: true, sms: false },

    # Project / Contractor notifications
    contractor_task_assigned: { in_app: true, email: true, sms: false, push: true },
    contractor_review_submitted: { in_app: true, email: true, sms: false, push: false },
    contractor_review_revision: { in_app: true, email: true, sms: false, push: false }
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
      # An ineligible type can never push, so its stored flag stays false no
      # matter what a bulk update writes.
      pref.push_enabled = defaults[:push] == true && Notification.push_eligible?(notification_type)
      pref.frequency = 'immediate'
    end
  end

  # Whether this type is even offered as a push toggle in the preferences UI.
  def push_available?
    Notification.push_eligible?(notification_type)
  end

  def push_active?
    push_enabled && push_available?
  end

  # Surfaces the eligibility flag to the client so the UI can hide the toggle
  # instead of offering a switch that silently does nothing.
  def as_json(options = {})
    super(options).merge('push_available' => push_available?)
  end

  # Check if delivery should happen based on quiet hours
  def should_deliver_now?
    return true unless respect_quiet_hours
    return true if quiet_hours_start.blank? || quiet_hours_end.blank?
    
    # User has no time_zone column, so a bare `user.time_zone` raised
    # NoMethodError for anyone who switched quiet hours on. It went unnoticed
    # because respect_quiet_hours defaults to false and the guard above returns
    # first; push made it reachable, so resolve it defensively.
    current_time = Time.current.in_time_zone(user.try(:time_zone).presence || 'America/Denver')
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

  private

  def clear_push_for_ineligible_type
    self.push_enabled = false unless push_available?
    true
  end
end
