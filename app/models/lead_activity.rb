# frozen_string_literal: true

class LeadActivity < ApplicationRecord
  include ActivityTrackable

  belongs_to :lead
  belongs_to :user # creator
  belongs_to :assigned_to, class_name: 'User', optional: true
  belongs_to :related_activity, class_name: 'LeadActivity', optional: true
  has_many :follow_up_activities, class_name: 'LeadActivity', foreign_key: :related_activity_id, dependent: :nullify
  
  # Serialize reminder_method as JSON array for SQLite compatibility
  serialize :reminder_method, coder: JSON
  
  ACTIVITY_TYPES = %w[task meeting call reminder note].freeze
  STATUSES = %w[pending in_progress completed cancelled].freeze
  PRIORITIES = %w[low medium high urgent].freeze
  CALL_DIRECTIONS = %w[inbound outbound].freeze
  CALL_OUTCOMES = %w[answered voicemail no_answer busy].freeze
  REMINDER_METHODS = %w[email popup sms].freeze
  
  validates :activity_type, presence: true, inclusion: { in: ACTIVITY_TYPES }
  validates :subject, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :call_direction, inclusion: { in: CALL_DIRECTIONS }, if: -> { activity_type == 'call' }
  validates :call_outcome, inclusion: { in: CALL_OUTCOMES }, if: -> { call_outcome.present? }
  
  validate :validate_activity_type_fields
  
  scope :tasks, -> { where(activity_type: 'task') }
  scope :meetings, -> { where(activity_type: 'meeting') }
  scope :calls, -> { where(activity_type: 'call') }
  scope :reminders, -> { where(activity_type: 'reminder') }
  scope :pending, -> { where(status: 'pending') }
  scope :completed, -> { where(status: 'completed') }
  scope :overdue, -> { where('due_date < ? AND status != ?', Time.current, 'completed') }
  scope :upcoming, -> { where('due_date > ? AND status = ?', Time.current, 'pending').order(due_date: :asc) }
  scope :for_user, ->(user_id) { where(assigned_to_id: user_id) }
  
  after_create :schedule_reminders, if: -> { ['reminder', 'call', 'task', 'meeting'].include?(activity_type) && reminder_time.present? }
  after_update :reschedule_reminders_if_changed, if: -> { ['reminder', 'call', 'task', 'meeting'].include?(activity_type) && reminder_time.present? && saved_change_to_reminder_time? }
  after_update :update_lead_last_activity
  after_save :create_activity_log
  before_validation :ensure_reminder_method_array
  before_validation :set_meeting_reminder_time, if: -> { activity_type == 'meeting' && start_time.present? }
  before_validation :set_task_reminder_time, if: -> { activity_type == 'task' && due_date.present? }
  
  def complete!
    update!(status: 'completed', completed_at: Time.current)
  end
  
  def cancel!
    update!(status: 'cancelled')
  end
  
  def overdue?
    due_date && due_date < Time.current && status != 'completed'
  end

  def activity_display_name
    subject || 'Activity'
  end

  def activity_module_name
    'crm'
  end

  def activity_account_id
    lead&.converted_account_id
  end

  def activity_location_id
    lead&.location_id
  end

  # Must be public - ActivityTrackable concern uses try(:company)
  def company
    lead&.company
  end

  private

  def ensure_reminder_method_array
    if reminder_method.is_a?(String)
      self.reminder_method = JSON.parse(reminder_method) rescue []
    elsif reminder_method.nil?
      self.reminder_method = []
    end
  end
  
  def set_meeting_reminder_time
    # Auto-set reminder_time to 15 minutes before meeting starts if not already set
    if reminder_time.nil?
      self.reminder_time = start_time - 15.minutes
      self.reminder_method ||= ['popup']  # Default to popup notifications
    end
  end
  
  def set_task_reminder_time
    # Auto-set reminder_time to task due date if not already set
    if reminder_time.nil?
      self.reminder_time = due_date
      self.reminder_method ||= ['popup']  # Default to popup notifications
    end
  end
  
  def validate_activity_type_fields
    case activity_type
    when 'meeting'
      errors.add(:start_time, 'is required for meetings') if start_time.blank?
      errors.add(:end_time, 'is required for meetings') if end_time.blank?
    when 'call'
      errors.add(:phone_number, 'is required for calls') if phone_number.blank?
      errors.add(:call_direction, 'is required for calls') if call_direction.blank?
    when 'reminder'
      errors.add(:reminder_time, 'is required for reminders') if reminder_time.blank?
      # Note: reminder_method validation removed - using unified notification system
      # User preferences in notification_settings control which channels are used
    end
  end
  
  def schedule_reminders
    return unless reminder_time && !reminder_sent
    
    delay = (reminder_time - Time.current).to_i
    
    # If reminder time is in the past or within next minute, send immediately
    if delay <= 60
      Rails.logger.info "[LeadActivity] Reminder time is past or very soon, sending immediately for activity #{id}"
      ActivityReminderService.send_reminder(self)
      update_column(:reminder_sent, true)
    else
      # Schedule for future
      ActivityReminderJob.set(wait: delay.seconds).perform_later(id, 'LeadActivity')
      Rails.logger.info "[LeadActivity] Scheduled reminder job for activity #{id} in #{delay} seconds"
    end
  rescue => e
    Rails.logger.error "[LeadActivity] Failed to schedule reminder: #{e.message}"
  end
  
  def reschedule_reminders_if_changed
    # Reset reminder_sent flag when reminder_time changes
    update_column(:reminder_sent, false)
    schedule_reminders
    Rails.logger.info "[LeadActivity] Rescheduled reminder for activity #{id}"
  rescue => e
    Rails.logger.error "[LeadActivity] Failed to reschedule reminder: #{e.message}"
  end
  
  def update_lead_last_activity
    lead.touch(:updated_at) if lead
  rescue => e
    Rails.logger.error "[LeadActivity] Failed to touch lead: #{e.message}"
  end
  
  def create_activity_log
    # Log to the existing Activity model for timeline
    Activity.create!(
      lead: lead,
      user: user,
      activity_type: "lead_activity_#{activity_type}",
      description: "#{activity_type.titleize}: #{subject}",
      metadata: {
        lead_activity_id: id,
        status: status,
        priority: priority
      }
    )
  rescue => e
    Rails.logger.error "[LeadActivity] Failed to create activity log: #{e.message}"
  end
end
