# frozen_string_literal: true

class QuickbooksSyncLog < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :quickbooks_sync_mapping, optional: true
  
  validates :operation, :entity_type, :status, presence: true
  
  scope :successful, -> { where(status: 'success') }
  scope :failed, -> { where(status: 'error') }
  scope :pending, -> { where(status: 'pending') }
  scope :for_entity, ->(type) { where(entity_type: type) }
  scope :slow_operations, ->(threshold_ms = 5000) { where('duration_ms > ?', threshold_ms) }
  
  def mark_success!(response = nil)
    update!(
      status: 'success',
      completed_at: Time.current,
      duration_ms: calculate_duration,
      response_data: response
    )
  end
  
  def mark_error!(error_message, response = nil)
    update!(
      status: 'error',
      error_message: error_message,
      completed_at: Time.current,
      duration_ms: calculate_duration,
      response_data: response
    )
  end
  
  def mark_skipped!(reason)
    update!(
      status: 'skipped',
      error_message: reason,
      completed_at: Time.current
    )
  end
  
  def retry!
    update!(status: 'pending', error_message: nil, started_at: Time.current)
  end
  
  def duration_seconds
    duration_ms ? (duration_ms / 1000.0).round(2) : nil
  end
  
  private
  
  def calculate_duration
    return nil unless started_at
    ((Time.current - started_at) * 1000).round(2)
  end
  
  class << self
    def success_rate(time_period = 24.hours)
      logs = where('created_at >= ?', time_period.ago)
      return 0 if logs.count.zero?
      (logs.successful.count.to_f / logs.count * 100).round(2)
    end
    
    def average_duration(time_period = 24.hours)
      where('created_at >= ?', time_period.ago)
        .where.not(duration_ms: nil)
        .average(:duration_ms)
        &.round(2)
    end
    
    def error_summary(time_period = 24.hours)
      failed.where('created_at >= ?', time_period.ago)
        .group(:error_message)
        .count
        .sort_by { |_, count| -count }
    end
  end
end
