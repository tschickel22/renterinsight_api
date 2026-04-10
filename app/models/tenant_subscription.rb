# frozen_string_literal: true

class TenantSubscription < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :subscription_plan
  
  # Validations
  validates :status, presence: true, inclusion: { 
    in: %w[active trial past_due cancelled suspended] 
  }
  validates :billing_cycle, inclusion: { in: %w[monthly annual] }
  validates :company_id, uniqueness: { 
    scope: :status, 
    conditions: -> { where(status: %w[active trial]) },
    message: 'already has an active subscription'
  }
  
  # Scopes
  scope :active, -> { where(status: %w[active trial]) }
  scope :cancelled, -> { where(status: 'cancelled') }
  scope :past_due, -> { where(status: 'past_due') }
  scope :in_trial, -> { where(status: 'trial') }
  scope :expiring_soon, -> { where('current_period_end <= ?', 7.days.from_now) }
  scope :trial_expiring_soon, -> { in_trial.where('trial_ends_at <= ?', 7.days.from_now) }
  scope :with_plan, -> { includes(:subscription_plan) }
  
  # Callbacks
  before_validation :set_defaults, on: :create
  after_save :sync_company_fields
  after_commit :bust_tenant_basic_cache
  
  # Status Constants
  STATUS_ACTIVE = 'active'
  STATUS_TRIAL = 'trial'
  STATUS_PAST_DUE = 'past_due'
  STATUS_CANCELLED = 'cancelled'
  STATUS_SUSPENDED = 'suspended'
  
  # Status checks
  def active?
    status == STATUS_ACTIVE
  end
  
  def trial?
    status == STATUS_TRIAL
  end
  
  def past_due?
    status == STATUS_PAST_DUE
  end
  
  def cancelled?
    status == STATUS_CANCELLED
  end
  
  def suspended?
    status == STATUS_SUSPENDED
  end
  
  def usable?
    active? || trial? || (past_due? && in_grace_period?)
  end
  
  def in_grace_period?
    in_grace_period && grace_period_ends_at.present? && grace_period_ends_at > Time.current
  end
  
  def trial_expired?
    trial? && trial_ends_at.present? && trial_ends_at < Time.current
  end
  
  def trial_days_remaining
    return 0 unless trial? && trial_ends_at.present?
    [(trial_ends_at.to_date - Date.current).to_i, 0].max
  end
  
  def grace_period_days_remaining
    return 0 unless in_grace_period?
    [(grace_period_ends_at.to_date - Date.current).to_i, 0].max
  end
  
  # Plan delegation
  def plan_name
    subscription_plan&.name
  end
  
  def plan_display_name
    subscription_plan&.display_name
  end
  
  def max_users
    subscription_plan&.max_users
  end
  
  def max_storage_gb
    subscription_plan&.max_storage_gb
  end
  
  def max_locations
    subscription_plan&.max_locations
  end
  
  # Usage checks
  def can_add_user?
    return true if max_users.nil?
    current_users < max_users
  end
  
  def can_add_location?
    return true if max_locations.nil?
    current_locations < max_locations
  end
  
  def users_remaining
    return Float::INFINITY if max_users.nil?
    [max_users - current_users, 0].max
  end
  
  def locations_remaining
    return Float::INFINITY if max_locations.nil?
    [max_locations - current_locations, 0].max
  end
  
  def user_usage_percentage
    return 0 if max_users.nil? || max_users.zero?
    (current_users.to_f / max_users * 100).round
  end
  
  def storage_usage_percentage
    return 0 if max_storage_gb.nil? || max_storage_gb.zero?
    (current_storage_gb.to_f / max_storage_gb * 100).round
  end
  
  # Update usage counts (call this periodically or on user/location changes)
  def refresh_usage!
    update!(
      current_users: company.users.where(deleted_at: nil).count,
      current_locations: company.locations.count,
      current_storage_gb: calculate_storage_usage
    )
  end
  
  # Lifecycle actions
  def activate!
    update!(
      status: STATUS_ACTIVE,
      current_period_start: Time.current,
      current_period_end: billing_cycle == 'annual' ? 1.year.from_now : 1.month.from_now
    )
  end
  
  def start_trial!(days = nil)
    trial_length = days || subscription_plan&.trial_days || 14
    update!(
      status: STATUS_TRIAL,
      trial_ends_at: trial_length.days.from_now,
      current_period_start: Time.current,
      current_period_end: trial_length.days.from_now
    )
  end
  
  def cancel!(reason = nil)
    update!(
      status: STATUS_CANCELLED,
      cancelled_at: Time.current,
      cancellation_reason: reason
    )
  end
  
  def suspend!
    update!(status: STATUS_SUSPENDED)
  end
  
  def mark_past_due!(grace_days = 7)
    update!(
      status: STATUS_PAST_DUE,
      in_grace_period: true,
      grace_period_ends_at: grace_days.days.from_now
    )
  end
  
  # Change plan
  def change_plan!(new_plan, billing_cycle: nil)
    self.subscription_plan = new_plan
    self.billing_cycle = billing_cycle if billing_cycle.present?
    
    # Reset period dates
    self.current_period_start = Time.current
    self.current_period_end = self.billing_cycle == 'annual' ? 1.year.from_now : 1.month.from_now
    
    save!
  end
  
  # Serialize for API response
  def as_json_detailed
    {
      id: id,
      company_id: company_id,
      plan: subscription_plan&.as_json_with_modules,
      status: status,
      billing_cycle: billing_cycle,
      current_period: {
        start: current_period_start,
        end: current_period_end
      },
      trial: trial? ? {
        ends_at: trial_ends_at,
        days_remaining: trial_days_remaining
      } : nil,
      grace_period: in_grace_period? ? {
        ends_at: grace_period_ends_at,
        days_remaining: grace_period_days_remaining
      } : nil,
      usage: {
        users: { current: current_users, max: max_users, remaining: users_remaining },
        storage_gb: { current: current_storage_gb, max: max_storage_gb },
        locations: { current: current_locations, max: max_locations, remaining: locations_remaining }
      },
      zoho: {
        subscription_id: zoho_subscription_id,
        customer_id: zoho_customer_id
      },
      created_at: created_at,
      updated_at: updated_at
    }
  end
  
  private

  def bust_tenant_basic_cache
    Rails.cache.delete_matched("tenant_basic/#{company_id}/*")
  rescue NotImplementedError
    Company.where(id: company_id).update_all(updated_at: Time.current)
  end

  def set_defaults
    self.billing_cycle ||= 'monthly'
    self.current_period_start ||= Time.current
    self.current_period_end ||= 1.month.from_now
  end
  
  def sync_company_fields
    # Keep company fields in sync for backward compatibility
    company.update_columns(
      subscription_tier: subscription_plan&.category,
      max_users: max_users,
      max_storage_gb: max_storage_gb,
      zoho_subscription_id: zoho_subscription_id,
      zoho_customer_id: zoho_customer_id
    )
  end
  
  def calculate_storage_usage
    # Placeholder - implement actual storage calculation
    # Could sum Active Storage attachments for company
    0
  end
end
