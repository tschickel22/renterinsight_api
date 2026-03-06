class Deal < ApplicationRecord
  include LocationAware
  include NotifiableDeal
  include WebhookNotifiable
  
  belongs_to :company, optional: true
  belongs_to :location, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :user, optional: true  # FIX: Made optional to prevent 422 errors when user_id not set
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  belongs_to :territory, optional: true
  belongs_to :source, optional: true
  belongs_to :vehicle, optional: true  # Added vehicle relationship
  belongs_to :commission_plan, optional: true  # Commission plan for this deal
  
  # Deal participants for commission calculation
  belongs_to :primary_salesperson, class_name: 'User', foreign_key: 'primary_salesperson_id', optional: true
  belongs_to :sales_manager, class_name: 'User', foreign_key: 'sales_manager_id', optional: true
  belongs_to :finance_manager, class_name: 'User', foreign_key: 'finance_manager_id', optional: true
  belongs_to :desk_manager, class_name: 'User', foreign_key: 'desk_manager_id', optional: true
  belongs_to :secondary_salesperson, class_name: 'User', foreign_key: 'secondary_salesperson_id', optional: true
  
  has_many :deal_products, dependent: :destroy
  has_many :deal_stage_histories, dependent: :destroy
  has_many :approval_workflows, dependent: :destroy
  has_one :win_loss_report, dependent: :destroy
  has_many :activities, class_name: 'DealActivity', dependent: :destroy
  has_many :commission_payments, dependent: :destroy
  has_many :quotes, dependent: :nullify
  has_many :service_tickets, dependent: :nullify
  
  # Tags (polymorphic association)
  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
  
  # Owner helper methods
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end
  
  validates :name, presence: true
  validates :value, numericality: { greater_than_or_equal_to: 0 }
  validates :probability, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validate :stage_is_valid

  def stage_is_valid
    return if stage.blank?
    normalized = stage.downcase
    # Check against company pipeline stages if configured
    saved_stages = company ? Setting.get('Company', company_id, 'pipeline_stages', nil) : nil
    allowed = if saved_stages.is_a?(Array) && saved_stages.any?
      saved_stages.map { |s| (s['key'] || s[:key]).to_s.downcase }
    else
      %w[prospecting qualification needs_analysis proposal negotiation closing closed_won closed_lost]
    end
    unless allowed.include?(normalized)
      errors.add(:stage, "#{stage} is not a valid stage")
    end
  end
  
  # Ensure at least account or contact is present
  validate :account_or_contact_required
  
  # Auto-generate deal number on creation
  before_create :generate_deal_number

  # Normalize stage to lowercase before validation
  before_validation :normalize_stage
  
  # Sync primary_salesperson_id with owner_id for commission system
  before_validation :sync_primary_salesperson
  
  # Auto-assign commission plan based on salesperson/role/company default
  before_validation :auto_assign_commission_plan, if: -> { commission_plan_id.nil? && primary_salesperson_id.present? }
  
  # Sync vehicle pricing when vehicle is assigned
  before_validation :sync_vehicle_pricing, if: :will_save_change_to_vehicle_id?
  
  # Auto-generate commission payment when deal is marked closed_won
  after_save :generate_commission_payment, if: :just_closed_won?
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_stage?
  
  def normalize_stage
    self.stage = stage&.downcase
  end
  
  def account_or_contact_required
    if account_id.blank? && contact_id.blank?
      errors.add(:base, "Deal must have either an account or a contact")
    end
  end
  
  # Scopes
  scope :open, -> { where(stage: %w[prospecting qualification needs_analysis proposal negotiation closing]) }
  scope :won, -> { where(stage: 'closed_won') }
  scope :lost, -> { where(stage: 'closed_lost') }
  scope :by_stage, ->(stage) { where(stage: stage&.downcase) }
  scope :by_territory, ->(territory_id) { where(territory_id: territory_id) }
  scope :by_owner, ->(user_id) { where(user_id: user_id) }
  scope :by_contact, ->(contact_id) { where(contact_id: contact_id) }
  scope :by_vehicle, ->(vehicle_id) { where(vehicle_id: vehicle_id) }
  scope :expected_to_close, ->(date) { where('expected_close_date <= ?', date) }
  scope :recently_created, -> { where('created_at >= ?', 30.days.ago) }
  scope :recently_won, -> { where('won_at >= ?', 30.days.ago) }
  scope :recently_lost, -> { where('lost_at >= ?', 30.days.ago) }
  
  # Soft delete
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  
  def soft_delete
    update(deleted_at: Time.current)
  end
  
  def restore
    update(deleted_at: nil)
  end
  
  # Stage management
  def mark_as_won(reason: nil)
    update(
      stage: 'closed_won',
      won_at: Time.current,
      actual_close_date: Date.today,
      win_reason: reason
    )
  end
  
  def mark_as_lost(reason: nil, competitor: nil)
    update(
      stage: 'closed_lost',
      lost_at: Time.current,
      actual_close_date: Date.today,
      loss_reason: reason,
      competitor: competitor
    )
  end
  
  def closed?
    %w[closed_won closed_lost].include?(stage)
  end
  
  def open?
    !closed?
  end
  
  # Helper to get customer name from account or contact
  def customer_display_name
    # Prioritize manual customer_name field if set
    return customer_name if customer_name.present?
    
    # Otherwise, derive from account or contact
    if account
      account.name
    elsif contact
      "#{contact.first_name} #{contact.last_name}".strip
    else
      'Unknown'
    end
  end
  
  # Vehicle display helper
  def vehicle_display_name
    vehicle&.display_name
  end
  
  # ============================================================================
  # VALUE CALCULATIONS
  # ============================================================================
  
  # Calculate total deal value from line items (products).
  # If products exist, use their total. Otherwise fall back to selling_price or manual value.
  def calculated_value
    products_total = deal_products.sum(:total)
    if products_total > 0
      products_total.round(2)
    else
      (selling_price || value || 0).to_f.round(2)
    end
  end
  
  # ============================================================================
  # COMMISSION ECONOMICS CALCULATIONS
  # ============================================================================
  
  # FRONT GROSS (Sale Price - Cost - Trade Difference)
  def front_gross
    base_gross = (selling_price || 0) - (unit_cost || 0)
    trade_difference = (trade_payoff || 0) - (trade_allowance || 0)
    primary_gross = base_gross - trade_difference
    products_gross = deal_products.sum(:total)
    (primary_gross + products_gross).round(2)
  end
  
  # PACK (dealer holdback/administrative fee)
  def effective_pack_amount
    return pack_amount if pack_amount.present?
    return location.default_pack_amount if location&.default_pack_amount.present?
    company&.default_pack_amount || 0
  end
  
  # COMMISSIONABLE FRONT GROSS (what most dealers pay on)
  def commissionable_front_gross
    (front_gross - effective_pack_amount).round(2)
  end
  
  # BACK GROSS (finance & products)
  def back_gross
    ((finance_reserve || 0) + (product_margin || 0)).round(2)
  end
  
  # TOTAL GROSS
  def total_gross
    (front_gross + back_gross).round(2)
  end
  
  # ADD-ON GROSS (MH dealers pay separately on these)
  def addon_gross
    ((delivery_fee || 0) + (setup_fee || 0) + (skirting_fee || 0) + (accessories_total || 0)).round(2)
  end
  
  # Gross per unit (for multi-unit deals)
  def gross_per_unit
    units = (quantity || 1)
    units > 0 ? (total_gross / units).round(2) : 0
  end
  
  # Helper for checking if deal has trade
  def has_trade?
    trade_allowance.present? && trade_allowance > 0
  end
  
  # Validation: warn if trade has negative equity
  validate :trade_equity_check, if: :has_trade?
  
  def trade_equity_check
    if (trade_payoff || 0) > (trade_allowance || 0)
      negative_equity = ((trade_payoff || 0) - (trade_allowance || 0)).round(2)
      Rails.logger.warn("Deal #{id}: Negative equity of $#{negative_equity} (Payoff: $#{trade_payoff}, Allowance: $#{trade_allowance})")
    end
  end
  
  def delivered?
    stage == 'closed_won' && delivery_date.present?
  end
  
  def just_closed_won?
    saved_change_to_stage? && stage == 'closed_won'
  end
  
  def just_delivered?
    saved_change_to_stage? && stage == 'closed_won' && delivery_date.present?
  end
  
  # Primary salesperson helper (deprecated - use association)
  def primary_salesperson
    User.find_by(id: primary_salesperson_id)
  end
  
  # Get all deal participants for commission calculation
  def all_participants
    participants = []
    participants << { user: primary_salesperson, role: 'primary_salesperson' } if primary_salesperson_id.present?
    participants << { user: sales_manager, role: 'sales_manager' } if sales_manager_id.present?
    participants << { user: finance_manager, role: 'finance_manager' } if finance_manager_id.present?
    participants << { user: desk_manager, role: 'desk_manager' } if desk_manager_id.present?
    participants << { user: secondary_salesperson, role: 'secondary_salesperson' } if secondary_salesperson_id.present?
    participants.compact
  end
  
  # Determine which commission plan applies to this deal (PUBLIC - called from controller)
  def determine_commission_plan
    return commission_plan if commission_plan_id.present?
    
    salesperson = primary_salesperson || owner
    return nil unless salesperson && company
    
    user_plan = company.commission_plans
      .active.current
      .where(assigned_user_id: salesperson.id)
      .first
    return user_plan if user_plan
    
    if salesperson.role.present?
      role_plan = company.commission_plans
        .active.current
        .where(assigned_role: salesperson.role)
        .first
      return role_plan if role_plan
    end
    
    company.commission_plans.active.current.defaults.first
  end
  
  private
  
  # Auto-generate unique deal number per company (e.g. D-000001)
  def generate_deal_number
    return if deal_number.present?

    # Find the highest existing number for this company using safe SQL
    last_num = 0
    if company_id.present?
      result = self.class.connection.select_value(
        "SELECT MAX(CAST(SUBSTRING(deal_number FROM 3) AS INTEGER)) FROM deals " \
        "WHERE company_id = #{company_id} AND deal_number ~ '^D-[0-9]+$'"
      )
      last_num = result.to_i
    end

    self.deal_number = "D-#{(last_num + 1).to_s.rjust(6, '0')}"
  end

  # Auto-assign commission plan before save
  def auto_assign_commission_plan
    plan = determine_commission_plan
    self.commission_plan = plan if plan.present?
  end
  
  # Sync primary_salesperson_id with owner_id (for commission system)
  def sync_primary_salesperson
    self.primary_salesperson_id = owner_id
  end
  
  # Auto-generate commission payment when deal is delivered
  def generate_commission_payment
    return unless primary_salesperson_id.present?
    CommissionPaymentGeneratorService.generate_for_deal(self)
  rescue StandardError => e
    Rails.logger.error "[Deal] Failed to generate commission payment for deal #{id}: #{e.message}"
  end
  
  # Fire custom lifecycle webhook events on stage transitions
  def fire_lifecycle_webhooks
    event = case stage
            when 'closed_won'  then 'deal.won'
            when 'closed_lost' then 'deal.lost'
            end
    return unless event

    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Deal] Failed to fire lifecycle webhook #{event}: #{e.message}"
  end

  # Sync vehicle pricing data when vehicle is assigned
  def sync_vehicle_pricing
    return unless vehicle_id.present?
    vehicle = Vehicle.find_by(id: vehicle_id)
    return unless vehicle
    
    vehicle_price = vehicle.sale_price || vehicle.msrp
    self.selling_price = vehicle_price if selling_price.nil? || selling_price == 0
    self.unit_cost = vehicle.cost if unit_cost.nil? || unit_cost == 0
    self.value = vehicle_price if value.nil? || value == 0
    self.quantity ||= 1
    
    Rails.logger.info "[Deal] Synced pricing from vehicle #{vehicle_id}: selling_price=$#{selling_price}, unit_cost=$#{unit_cost}, value=$#{value}"
  rescue StandardError => e
    Rails.logger.error "[Deal] Failed to sync vehicle pricing: #{e.message}"
  end
end
