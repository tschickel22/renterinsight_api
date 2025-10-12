class AccountActivity < ApplicationRecord
  belongs_to :account
  belongs_to :user, optional: true # creator
  belongs_to :assigned_to, class_name: 'User', optional: true
  belongs_to :related_activity, class_name: 'AccountActivity', optional: true
  has_many :follow_up_activities, class_name: 'AccountActivity', foreign_key: :related_activity_id, dependent: :nullify
  
  # Serialize reminder_method as JSON array for SQLite compatibility
  serialize :reminder_method, coder: JSON
  
  ACTIVITY_TYPES = %w[task meeting call reminder email note status_change].freeze
  STATUSES = %w[pending in_progress completed cancelled].freeze
  PRIORITIES = %w[low medium high urgent].freeze
  CALL_DIRECTIONS = %w[inbound outbound].freeze
  CALL_OUTCOMES = %w[answered voicemail no_answer busy].freeze
  OUTCOMES = %w[positive neutral negative].freeze
  REMINDER_METHODS = %w[email popup sms].freeze
  
  validates :activity_type, presence: true, inclusion: { in: ACTIVITY_TYPES }
  validates :subject, presence: true, if: -> { %w[task meeting call reminder].include?(activity_type) }
  validates :description, presence: true, if: -> { %w[email note status_change].include?(activity_type) }
  validates :status, inclusion: { in: STATUSES }, if: -> { status.present? }
  validates :priority, inclusion: { in: PRIORITIES }, if: -> { priority.present? }
  validates :call_direction, inclusion: { in: CALL_DIRECTIONS }, if: -> { activity_type == 'call' && call_direction.present? }
  validates :call_outcome, inclusion: { in: CALL_OUTCOMES }, if: -> { call_outcome.present? }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_blank: true
  validates :duration, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  
  validate :validate_activity_type_fields
  
  scope :tasks, -> { where(activity_type: 'task') }
  scope :meetings, -> { where(activity_type: 'meeting') }
  scope :calls, -> { where(activity_type: 'call') }
  scope :reminders, -> { where(activity_type: 'reminder') }
  scope :emails, -> { where(activity_type: 'email') }
  scope :notes, -> { where(activity_type: 'note') }
  scope :pending, -> { where(status: 'pending') }
  scope :completed, -> { where(status: 'completed') }
  scope :overdue, -> { where('due_date < ? AND status != ?', Time.current, 'completed') }
  scope :upcoming, -> { where('due_date > ? AND status = ?', Time.current, 'pending').order(due_date: :asc) }
  scope :for_user, ->(user_id) { where(assigned_to_id: user_id) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_type, ->(type) { where(activity_type: type) }
  scope :with_outcome, -> { where.not(outcome: nil) }
  
  before_validation :ensure_reminder_method_array
  before_validation :set_defaults
  
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
  
  def set_defaults
    self.status ||= 'pending' if %w[task meeting call reminder].include?(activity_type)
    self.priority ||= 'medium' if %w[task meeting call reminder].include?(activity_type)
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
end
