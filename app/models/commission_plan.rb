class CommissionPlan < ApplicationRecord
  belongs_to :company
  belongs_to :assigned_user, class_name: 'User', foreign_key: 'assigned_user_id', optional: true
  belongs_to :location, optional: true
  
  has_many :commission_components, dependent: :nullify
  has_many :commission_payments
  
  validates :name, presence: true
  validates :company_id, presence: true
  validate :company_fee_percent_in_range
  
  scope :active, -> { where(is_active: true) }
  scope :for_user, ->(user_id) { where(assigned_user_id: user_id) }
  scope :for_role, ->(role) { where(assigned_role: role) }
  scope :defaults, -> { where(is_default: true) }
  scope :current, -> { where('(effective_date IS NULL OR effective_date <= ?) AND (expiration_date IS NULL OR expiration_date >= ?)', Date.today, Date.today) }
  
  # Location filtering scope (standard pattern)
  scope :for_current_location, -> {
    Current.location_filtered? ? where(location_id: Current.location_id) : all
  }
  
  # The plan that applies to a salesperson's deals. Priority: assigned to the
  # person, then to one of their roles, then the company default. Roles are the
  # RBAC role keys the plan form offers, plus the legacy users.role column.
  def self.for_salesperson(user, company)
    plans = company.commission_plans.active.current.order(created_at: :desc)

    plans.find_by(assigned_user_id: user.id) ||
      (role_keys_for(user, company).any? && plans.find_by(assigned_role: role_keys_for(user, company))) ||
      plans.defaults.first
  end

  def self.role_keys_for(user, company)
    rbac = user.user_role_assignments.joins(:role)
               .where('user_role_assignments.company_id = ? OR user_role_assignments.company_id IS NULL', company.id)
               .pluck('roles.key')
    (rbac + [user.try(:role)]).compact_blank.uniq
  end

  # Check if plan is valid for a given date
  def valid_for_date?(date = Date.today)
    (effective_date.nil? || effective_date <= date) &&
    (expiration_date.nil? || expiration_date >= date)
  end
  
  # What comes off the profit before percent commissions are figured, kept in
  # metadata as before_commission: { company_fee_percent:, fee_component_ids: }.
  # The company fee is a percent of the profit the company keeps. Fee components
  # are flat amounts this plan pays someone, taken off only when that person is on
  # the deal.
  def company_fee_percent
    metadata.to_h.dig('before_commission', 'company_fee_percent').to_d
  end

  def fee_component_ids
    Array(metadata.to_h.dig('before_commission', 'fee_component_ids')).map(&:to_i)
  end

  # Get active components
  def active_components
    commission_components
      .where(is_active: true)
      .order(:sequence)
  end

  private

  def company_fee_percent_in_range
    return if company_fee_percent.between?(0, 100)

    errors.add(:base, 'Admin fee must be between 0% and 100%')
  end
end
