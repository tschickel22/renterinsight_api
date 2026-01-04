# frozen_string_literal: true

# Service to generate commission payments from deals
# Reads deal economics + salesperson's active commission components
# Calculates each component, creates payment with line-item breakdown
class CommissionPaymentGeneratorService
  
  # Generate commission payment for a delivered deal
  # @param deal [Deal] The delivered deal
  # @return [CommissionPayment, nil] The created payment or nil if skipped
  def self.generate_for_deal(deal)
    new(deal).generate
  end
  
  # Preview commission calculation without creating payment
  # @param deal [Deal] The deal to preview
  # @return [Hash] Preview data with line items and totals
  def self.preview_for_deal(deal)
    new(deal).preview
  end
  
  def initialize(deal)
    @deal = deal
    @company = deal.company
    @salesperson = deal.primary_salesperson
    @errors = []
  end
  
  # Main generation method
  def generate
    Rails.logger.info "[CommissionPaymentGenerator] 🎯 Starting generation for Deal ##{@deal.id}"
    
    # Validation checks
    return skip_generation("No company") unless @company.present?
    return skip_generation("No salesperson assigned") unless @salesperson.present?
    return skip_generation("Deal not delivered") unless @deal.delivered?
    return skip_generation("Payment already exists") if payment_already_exists?
    
    # Get active commission plan for salesperson
    active_plan = get_active_commission_plan
    return skip_generation("No active commission plan") unless active_plan.present?
    
    # Get active components
    components = get_active_components(active_plan)
    return skip_generation("No active commission components") if components.empty?
    
    # Calculate payment
    payment = create_payment(active_plan, components)
    
    if payment.persisted?
      Rails.logger.info "[CommissionPaymentGenerator] ✅ Payment ##{payment.id} created for Deal ##{@deal.id}: $#{payment.amount}"
      payment
    else
      Rails.logger.error "[CommissionPaymentGenerator] ❌ Failed to create payment: #{payment.errors.full_messages.join(', ')}"
      nil
    end
  rescue StandardError => e
    Rails.logger.error "[CommissionPaymentGenerator] ❌ Error: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    nil
  end
  
  # Preview commission calculation without creating payment
  def preview
    Rails.logger.info "[CommissionPaymentGenerator] 🔍 Previewing for Deal ##{@deal.id}"
    
    # Return error structure if validations fail
    return preview_error("No company") unless @company.present?
    return preview_error("No salesperson assigned") unless @salesperson.present?
    
    # Get active commission plan
    active_plan = get_active_commission_plan
    return preview_error("No active commission plan for #{@salesperson.name}") unless active_plan.present?
    
    # Get active components
    components = get_active_components(active_plan)
    return preview_error("No active commission components in plan '#{active_plan.name}'") if components.empty?
    
    # Calculate line items
    line_items_data = []
    total_amount = 0
    
    components.each do |component|
      amount = calculate_component(component)
      
      next if amount <= 0
      
      line_items_data << {
        componentName: component.name,
        calculationBasis: component.calculation_basis.humanize,
        calculationMethod: component.calculation_method.humanize,
        rate: component.rate,
        basisAmount: get_basis_amount(component).round(2),
        calculatedAmount: amount.round(2)
      }
      
      total_amount += amount
    end
    
    # Return preview structure
    {
      canGenerate: @deal.delivered?,
      dealId: @deal.id,
      dealName: @deal.name,
      salespersonId: @salesperson.id,
      salespersonName: @salesperson.name,
      planId: active_plan.id,
      planName: active_plan.name,
      lineItems: line_items_data,
      totalAmount: total_amount.round(2),
      dealEconomics: {
        sellingPrice: @deal.selling_price || 0,
        unitCost: @deal.unit_cost || 0,
        frontGross: @deal.front_gross,
        backGross: @deal.back_gross,
        totalGross: @deal.total_gross,
        addonGross: @deal.addon_gross,
        commissionableFrontGross: @deal.commissionable_front_gross
      },
      paymentExists: payment_already_exists?,
      isDelivered: @deal.delivered?
    }
  rescue StandardError => e
    Rails.logger.error "[CommissionPaymentGenerator] ❌ Preview Error: #{e.message}"
    preview_error(e.message)
  end
  
  def preview_error(message)
    {
      canGenerate: false,
      error: message,
      lineItems: [],
      totalAmount: 0
    }
  end
  
  private
  
  def skip_generation(reason)
    Rails.logger.info "[CommissionPaymentGenerator] ⏭️  Skipping: #{reason}"
    nil
  end
  
  def payment_already_exists?
    @company.commission_payments
      .where(deal_id: @deal.id, payee_user_id: @salesperson.id)
      .where.not(is_reversed: true)
      .exists?
  end
  
  def get_active_commission_plan
    # Find active plan for this salesperson
    # Plans can be:
    # 1. User-specific (assigned_user_id matches)
    # 2. Role-based (applies to user's role)
    # 3. Company-wide default (no assignment filters)
    
    plans = @company.commission_plans
      .active
      .where('effective_date <= ?', @deal.delivery_date || Date.today)
      .where('expiration_date IS NULL OR expiration_date >= ?', @deal.delivery_date || Date.today)
    
    # Priority: User-specific > Role-based > Company default
    user_plan = plans.where(assigned_user_id: @salesperson.id).first
    return user_plan if user_plan.present?
    
    role_plan = plans.where(assigned_role: @salesperson.role).first
    return role_plan if role_plan.present?
    
    # Company default (no filters)
    plans.where(assigned_user_id: nil, assigned_role: nil).first
  end
  
  def get_active_components(plan)
    plan.commission_components
      .active
      .where('effective_date <= ?', @deal.delivery_date || Date.today)
      .where('expiration_date IS NULL OR expiration_date >= ?', @deal.delivery_date || Date.today)
      .order(:display_order)
  end
  
  def create_payment(plan, components)
    line_items_data = []
    total_amount = 0
    
    # Calculate each component
    components.each do |component|
      amount = calculate_component(component)
      
      next if amount <= 0 # Skip zero amounts
      
      line_items_data << {
        commission_component_id: component.id,
        description: component.name,
        calculation_basis: component.calculation_basis,
        calculation_method: component.calculation_method,
        rate: component.rate,
        basis_amount: get_basis_amount(component),
        calculated_amount: amount
      }
      
      total_amount += amount
    end
    
    # Create payment with line items
    payment = @company.commission_payments.build(
      deal_id: @deal.id,
      payee_user_id: @salesperson.id,
      commission_plan_id: plan.id,
      amount: total_amount.round(2),
      status: 'pending',
      earned_date: @deal.delivery_date || Date.today,
      location_id: @deal.location_id,
      notes: "Auto-generated from Deal ##{@deal.id} - #{@deal.name}"
    )
    
    # Build line items
    line_items_data.each do |line_data|
      payment.commission_payment_line_items.build(line_data)
    end
    
    payment.save
    payment
  end
  
  # Calculate commission for a single component
  def calculate_component(component)
    basis_amount = get_basis_amount(component)
    
    case component.calculation_method
    when 'flat_rate'
      # Fixed dollar amount per deal
      component.rate || 0
      
    when 'percentage'
      # Percentage of basis amount
      rate = (component.rate || 0) / 100.0
      (basis_amount * rate).round(2)
      
    when 'tiered'
      # Tiered percentage based on amount thresholds
      calculate_tiered(component, basis_amount)
      
    when 'per_unit'
      # Dollar amount per unit sold
      units = @deal.quantity || 1
      ((component.rate || 0) * units).round(2)
      
    else
      Rails.logger.warn "[CommissionPaymentGenerator] ⚠️  Unknown calculation method: #{component.calculation_method}"
      0
    end
  end
  
  # Get the dollar amount to calculate commission on
  def get_basis_amount(component)
    case component.calculation_basis
    when 'front_gross'
      @deal.front_gross
      
    when 'commissionable_front_gross'
      @deal.commissionable_front_gross
      
    when 'back_gross'
      @deal.back_gross
      
    when 'total_gross'
      @deal.total_gross
      
    when 'addon_gross'
      @deal.addon_gross
      
    when 'selling_price'
      @deal.selling_price || 0
      
    when 'finance_reserve'
      @deal.finance_reserve || 0
      
    when 'product_margin'
      @deal.product_margin || 0
      
    when 'accessories'
      @deal.accessories_total || 0
      
    when 'delivery_setup'
      (@deal.delivery_fee || 0) + (@deal.setup_fee || 0)
      
    else
      Rails.logger.warn "[CommissionPaymentGenerator] ⚠️  Unknown basis: #{component.calculation_basis}"
      0
    end
  end
  
  # Calculate tiered commission
  # Tiers stored as JSON: [{"min": 0, "max": 5000, "rate": 5}, {"min": 5001, "max": null, "rate": 8}]
  def calculate_tiered(component, basis_amount)
    return 0 unless component.tier_structure.present?
    
    tiers = if component.tier_structure.is_a?(String)
      JSON.parse(component.tier_structure)
    else
      component.tier_structure
    end
    
    return 0 unless tiers.is_a?(Array)
    
    total = 0
    
    tiers.each do |tier|
      min = tier['min'] || 0
      max = tier['max']
      rate = (tier['rate'] || 0) / 100.0
      
      # Amount falls within this tier?
      next if basis_amount < min
      
      if max.present?
        # Tier has a ceiling
        tier_amount = [basis_amount, max].min - min + 1
        total += (tier_amount * rate).round(2)
      else
        # Open-ended tier
        tier_amount = basis_amount - min + 1
        total += (tier_amount * rate).round(2)
        break # Last tier
      end
    end
    
    total
  end
end
