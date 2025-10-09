# frozen_string_literal: true

class LeadActivity < ApplicationRecord
  belongs_to :lead
  belongs_to :user # creator
  belongs_to :assigned_to, class_name: 'User', optional: true
  belongs_to :related_activity, class_name: 'LeadActivity', optional: true
  has_many :follow_up_activities, class_name: 'LeadActivity', foreign_key: :related_activity_id, dependent: :nullify
  
  # Serialize reminder_method as JSON array for SQLite compatibility
  serialize :reminder_method, coder: JSON
  
  ACTIVITY_TYPES = %w[task meeting call reminder].freeze
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
  
  after_create :schedule_reminders, if: -> { activity_type == 'reminder' }
  after_create :send_creation_notifications
  after_update :reschedule_reminders_if_changed, if: -> { activity_type == 'reminder' && saved_change_to_reminder_time? }
  after_update :update_lead_last_activity
  after_save :create_activity_log
  before_validation :ensure_reminder_method_array
  
  def complete!
    update!(status: 'completed', completed_at: Time.current)
  end
  
  def cancel!
    update!(status: 'cancelled')
  end
  
  def overdue?
    due_date && due_date < Time.current && status != 'completed'
  end
  
  private
  
  def ensure_reminder_method_array
    if reminder_method.is_a?(String)
      self.reminder_method = JSON.parse(reminder_method) rescue []
    elsif reminder_method.nil?
      self.reminder_method = []
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
      if reminder_method.blank? || (reminder_method.is_a?(Array) && reminder_method.empty?)
        errors.add(:reminder_method, 'must have at least one method')
      end
    end
  end
  
  def schedule_reminders
    return unless reminder_time && !reminder_sent
    
    delay = (reminder_time - Time.current).to_i
    if delay > 0
      ActivityReminderJob.set(wait: delay.seconds).perform_later(id)
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
  
  def send_creation_notifications
    ActivityNotificationService.new(self).send_all_notifications
  rescue => e
    Rails.logger.error "[LeadActivity] Failed to send notifications: #{e.message}"
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
