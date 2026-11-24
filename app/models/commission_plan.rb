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

  # What a component set to "What this plan pays on" (gross_type plan_basis)
  # counts, kept in metadata as pays_on. The home always counts; title and
  # license fees never do. Costs: whether freight the dealer pays and the
  # dealer pack come off. Unset keys take these defaults.
  PAYS_ON_INCOME = %w[freight delivery_setup addons doc_fee land fi_products].freeze
  PAYS_ON_COSTS = %w[freight_cost pack].freeze
  PAYS_ON_DEFAULTS = {
    'freight' => true, 'delivery_setup' => true, 'addons' => true, 'doc_fee' => false, 'land' => true,
    'fi_products' => false, 'freight_cost' => true, 'pack' => true
  }.freeze

  def pays_on
    saved = metadata.to_h['pays_on'].to_h.slice(*PAYS_ON_DEFAULTS.keys)
    PAYS_ON_DEFAULTS.merge(saved.transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) ? true : false })
  end

  # The primary salesperson's share when two salespeople split a deal (50 = 50/50).
  def split_primary_pct
    value = metadata.to_h.dig('split', 'primary_pct')
    value.present? ? value.to_d : BigDecimal('50')
  end

  # When this plan's commissions become payable: 'gl_approval', 'deal_closed',
  # or nil to follow the company setting (CommissionSettings).
  def payable_at
    value = metadata.to_h['payable_at']
    CommissionSettings::PAYABLE_AT.include?(value) ? value : nil
  end

  # Get active components
  def active_components
    commission_components
      .where(is_active: true)
      .order(:sequence)
  end

  private

  def company_fee_percent_in_range
    errors.add(:base, 'Admin fee must be between 0% and 100%') unless company_fee_percent.between?(0, 100)
    errors.add(:base, 'The primary salesperson\'s share must be between 0% and 100%') unless split_primary_pct.between?(0, 100)
    value = metadata.to_h['payable_at']
    errors.add(:base, 'When commission is paid must be at approval, at close, or the company setting') if value.present? && payable_at.nil?
  end
end
