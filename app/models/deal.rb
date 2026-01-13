class Deal < ApplicationRecord
  include LocationAware
  include NotifiableDeal
  
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
  
  has_many :deal_products, dependent: :destroy
  has_many :deal_stage_histories, dependent: :destroy
  has_many :approval_workflows, dependent: :destroy
  has_one :win_loss_report, dependent: :destroy
  has_many :activities, class_name: 'DealActivity', dependent: :destroy
  has_many :commission_payments, dependent: :destroy
  
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
  validates :stage, presence: true, inclusion: { 
    in: %w[
      prospecting qualification needs_analysis proposal 
      negotiation closing closed_won closed_lost
      PROSPECTING QUALIFICATION NEEDS_ANALYSIS PROPOSAL 
      NEGOTIATION CLOSING CLOSED_WON CLOSED_LOST
    ], 
    message: "%{value} is not a valid stage" 
  }
  
  # Ensure at least account or contact is present
  validate :account_or_contact_required
  
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
  
  # Calculate total deal value including selling price and all products
  def calculated_value
    base_value = selling_price || 0
    products_total = deal_products.sum(:total)
    (base_value + products_total).round(2)
  end
  
  # ============================================================================
  # COMMISSION ECONOMICS CALCULATIONS
  # ============================================================================
  
  # FRONT GROSS (Sale Price - Cost - Trade Difference)
  def front_gross
    base_gross = (selling_price || 0) - (unit_cost || 0)
    trade_difference = (trade_payoff || 0) - (trade_allowance || 0)
    (base_gross - trade_difference).round(2)
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
      # This is just a warning - some deals have negative equity
      # Don't add error, just log for visibility
      Rails.logger.warn("Deal #{id}: Negative equity of $#{negative_equity} (Payoff: $#{trade_payoff}, Allowance: $#{trade_allowance})")
    end
  end
  
  # Helper to check if deal is delivered (for commission generation)
  def delivered?
    stage == 'closed_won' && delivery_date.present?
  end
  
  # Check if status just changed to closed_won (triggers commission payment generation)
  def just_closed_won?
    saved_change_to_stage? && stage == 'closed_won'
  end
  
  # Check if status just changed to delivered (legacy check)
  def just_delivered?
    saved_change_to_stage? && stage == 'closed_won' && delivery_date.present?
  end
  
  # Primary salesperson helper
  def primary_salesperson
    User.find_by(id: primary_salesperson_id)
  end
  
  private
  
  # Determine which commission plan applies to this deal
  def determine_commission_plan
    return commission_plan if commission_plan_id.present?
    
    salesperson = primary_salesperson || owner
    return nil unless salesperson && company
    
    # Priority 1: User-specific plan
    user_plan = company.commission_plans
      .active
      .current
      .where(assigned_user_id: salesperson.id)
      .first
    
    return user_plan if user_plan
    
    # Priority 2: Role-based plan
    if salesperson.role.present?
      role_plan = company.commission_plans
        .active
        .current
        .where(assigned_role: salesperson.role)
        .first
      
      return role_plan if role_plan
    end
    
    # Priority 3: Company default plan
    company.commission_plans.active.current.defaults.first
  end
  
  # Auto-assign commission plan before save
  def auto_assign_commission_plan
    plan = determine_commission_plan
    self.commission_plan = plan if plan.present?
  end
  
  # Sync primary_salesperson_id with owner_id (for commission system)
  def sync_primary_salesperson
    # Always keep primary_salesperson_id in sync with owner_id
    self.primary_salesperson_id = owner_id
  end
  
  # Auto-generate commission payment when deal is delivered
  def generate_commission_payment
    return unless primary_salesperson_id.present?
    
    CommissionPaymentGeneratorService.generate_for_deal(self)
  rescue StandardError => e
    Rails.logger.error "[Deal] Failed to generate commission payment for deal #{id}: #{e.message}"
    # Don't raise - we don't want to block the deal save if commission generation fails
  end
  
  # Sync vehicle pricing data when vehicle is assigned
  def sync_vehicle_pricing
    return unless vehicle_id.present?
    
    # Only sync if vehicle exists
    vehicle = Vehicle.find_by(id: vehicle_id)
    return unless vehicle
    
    # Sync pricing fields from vehicle to deal
    # Only update if deal field is blank or zero (don't overwrite manual entries > 0)
    vehicle_price = vehicle.sale_price || vehicle.msrp
    
    self.selling_price = vehicle_price if selling_price.nil? || selling_price == 0
    self.unit_cost = vehicle.cost if unit_cost.nil? || unit_cost == 0
    self.value = vehicle_price if value.nil? || value == 0
    
    # Auto-populate quantity if not set
    self.quantity ||= 1
    
    # Log the sync for debugging
    Rails.logger.info "[Deal] Synced pricing from vehicle #{vehicle_id}: selling_price=$#{selling_price}, unit_cost=$#{unit_cost}, value=$#{value}"
  rescue StandardError => e
    Rails.logger.error "[Deal] Failed to sync vehicle pricing: #{e.message}"
    # Don't raise - we don't want to block the deal save if vehicle sync fails
  end
end
