class CommissionPlan < ApplicationRecord
  belongs_to :company
  belongs_to :assigned_user, class_name: 'User', foreign_key: 'assigned_user_id', optional: true
  belongs_to :location, optional: true
  
  has_many :commission_components, dependent: :nullify
  has_many :commission_payments
  
  validates :name, presence: true
  validates :company_id, presence: true
  
  scope :active, -> { where(is_active: true) }
  scope :for_user, ->(user_id) { where(assigned_user_id: user_id) }
  scope :for_role, ->(role) { where(assigned_role: role) }
  scope :defaults, -> { where(is_default: true) }
  scope :current, -> { where('(effective_date IS NULL OR effective_date <= ?) AND (expiration_date IS NULL OR expiration_date >= ?)', Date.today, Date.today) }
  
  # Location filtering scope (standard pattern)
  scope :for_current_location, -> {
    Current.location_filtered? ? where(location_id: Current.location_id) : all
  }
  
  # Find the applicable plan for a user
  def self.for_salesperson(user, company)
    # Priority: User-specific > Role-based > Company default
    plan = company.commission_plans.active.current
                  .where(assigned_user_id: user.id)
                  .order(created_at: :desc)
                  .first
    
    return plan if plan.present?
    
    # Try role-based plan (check if user has role string attribute)
    if user.respond_to?(:role) && user.role.present?
      plan = company.commission_plans.active.current
                    .where(assigned_role: user.role)
                    .order(created_at: :desc)
                    .first
      
      return plan if plan.present?
    end
    
    # Fall back to company default
    company.commission_plans.active.current.defaults.first
  end
  
  # Check if plan is valid for a given date
  def valid_for_date?(date = Date.today)
    (effective_date.nil? || effective_date <= date) &&
    (expiration_date.nil? || expiration_date >= date)
  end
  
  # Get active components
  def active_components
    commission_components
      .where(is_active: true)
      .order(:sequence)
  end
end
