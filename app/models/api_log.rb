# frozen_string_literal: true

# ApiLog Model
#
# Tracks all external API calls made by the platform for debugging,
# monitoring, and audit purposes. Used by payment gateways, communication
# providers, and other integrations.

class ApiLog < ApplicationRecord
  # Associations
  belongs_to :company, optional: true
  
  # Constants
  STATUSES = %w[pending success failure error timeout].freeze
  PROVIDERS = %w[zego stripe twilio sendgrid aws zoho].freeze
  
  # Validations
  validates :provider, presence: true
  validates :status, inclusion: { in: STATUSES }
  
  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :successful, -> { where(status: 'success') }
  scope :failed, -> { where(status: %w[failure error timeout]) }
  scope :by_action, ->(action) { where(action: action) }
  scope :today, -> { where('created_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', Time.current.beginning_of_week) }
  scope :this_month, -> { where('created_at >= ?', Time.current.beginning_of_month) }
  
  # Callbacks
  before_save :calculate_duration
  
  # Instance methods
  def success?
    status == 'success'
  end
  
  def failed?
    %w[failure error timeout].include?(status)
  end
  
  def pending?
    status == 'pending'
  end
  
  def duration_seconds
    return nil unless duration_ms
    (duration_ms / 1000.0).round(2)
  end
  
  def mark_success!
    update!(
      status: 'success',
      completed_at: Time.current
    )
  end
  
  def mark_failure!
    update!(
      status: 'failure',
      completed_at: Time.current
    )
  end
  
  def mark_error!(error_message = nil)
    update!(
      status: 'error',
      response: error_message || response,
      completed_at: Time.current
    )
  end
  
  private
  
  def calculate_duration
    if started_at && completed_at
      self.duration_ms = ((completed_at - started_at) * 1000).to_i
    end
  end
end
