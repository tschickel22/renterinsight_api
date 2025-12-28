# frozen_string_literal: true

class QuickbooksSyncLog < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  
  # Validations
  validates :operation, presence: true
  validates :entity_type, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending success failed] }
  
  # Scopes
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }
  scope :for_entity, ->(entity_type) { where(entity_type: entity_type) }
  scope :successful, -> { where(status: 'success') }
  scope :failed, -> { where(status: 'failed') }
  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }
  
  # Class methods for stats
  def self.success_rate(period = 30.days)
    logs = where('created_at >= ?', period.ago)
    return 0 if logs.count.zero?
    
    (logs.successful.count.to_f / logs.count * 100).round(2)
  end
  
  def self.average_duration(period = 30.days)
    logs = where('created_at >= ?', period.ago).where.not(duration_ms: nil)
    return 0 if logs.count.zero?
    
    (logs.average(:duration_ms) || 0).round(2)
  end
  
  # Instance methods
  def duration_seconds
    return nil unless duration_ms
    (duration_ms / 1000.0).round(2)
  end
  
  def mark_success!(response_data = nil)
    update!(
      status: 'success',
      response_data: response_data,
      completed_at: Time.current,
      duration_ms: calculate_duration
    )
  end
  
  def mark_failed!(error_message, response_data = nil)
    update!(
      status: 'failed',
      error_message: error_message,
      response_data: response_data,
      completed_at: Time.current,
      duration_ms: calculate_duration
    )
  end
  
  # Alias for compatibility
  alias_method :mark_error!, :mark_failed!
  
  private
  
  def calculate_duration
    return nil unless started_at && completed_at
    ((completed_at - started_at) * 1000).to_i
  end
end
