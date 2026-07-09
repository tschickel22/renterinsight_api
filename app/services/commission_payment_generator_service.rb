# frozen_string_literal: true

class CommissionPaymentGeneratorService
  def self.generate_for_deal(deal)
    new(deal).generate
  end
  
  def self.preview_for_deal(deal)
    new(deal).preview
  end
  
  def initialize(deal)
    @deal = deal
  end
  
  def generate
    # Don't generate if deal not closed won
    return nil unless @deal.stage_is_won?
    
    # Don't generate if deal has no commission plan
    return nil unless @deal.commission_plan.present?
    
    # Generate commission payments for ALL participants
    payments = []
    
    # Process each participant role
    process_participant(:primary_salesperson, @deal.primary_salesperson_id, payments)
    process_participant(:sales_manager, @deal.sales_manager_id, payments)
    process_participant(:finance_manager, @deal.finance_manager_id, payments)
    process_participant(:desk_manager, @deal.desk_manager_id, payments)
    process_participant(:secondary_salesperson, @deal.secondary_salesperson_id, payments)
    
    payments.compact
  end
  
  def preview
    # Preview commissions for ALL participants
    previews = []
    
    preview_participant(:primary_salesperson, @deal.primary_salesperson_id, previews)
    preview_participant(:sales_manager, @deal.sales_manager_id, previews)
    preview_participant(:finance_manager, @deal.finance_manager_id, previews)
    preview_participant(:desk_manager, @deal.desk_manager_id, previews)
    preview_participant(:secondary_salesperson, @deal.secondary_salesperson_id, previews)
    
    {
      can_generate: can_generate?,
      reasons: generation_reasons,
      participants: previews,
      total_commission: previews.sum { |p| p[:estimated_amount] },
      deal_economics: build_deal_economics
    }
  end
  
  private
  
  def process_participant(role, user_id, payments)
    return unless user_id.present?
    
    # Skip if payment already exists for this user/deal combo
    return if CommissionPayment.exists?(
      deal_id: @deal.id,
      payee_user_id: user_id,
      is_deleted: [false, nil]
    )
    
    # Get components applicable to this role
    components = get_components_for_role(role)
    return if components.empty?
    
    # Calculate commission amount
    commission_amount = calculate_total_for_components(components)
    return if commission_amount <= 0
    
    # Build calculation details
    calculation_data = build_calculation_details_for_role(role, components)
    calculation_data[:line_items] = build_line_items_for_components(components)
    calculation_data[:deal_economics] = build_deal_economics
    calculation_data[:role] = role.to_s
    
    # Create the payment
    payment = @deal.company.commission_payments.create!(
      deal_id: @deal.id,
      payee_user_id: user_id,
      amount: commission_amount,
      status: 'pending',
      location_id: @deal.location_id,
      calculation_details: calculation_data
    )
    
    payments << payment
  end
  
  def preview_participant(role, user_id, previews)
    return unless user_id.present?
    
    user = User.find_by(id: user_id)
    return unless user
    
    # Get components applicable to this role
    components = get_components_for_role(role)
    return if components.empty?
    
    commission_amount = calculate_total_for_components(components)
    
    previews << {
      role: role.to_s,
      user_id: user_id,
      user_name: user.name,
      estimated_amount: commission_amount,
      components: components.map do |component|
        amount = calculate_component_amount(component)
        {
          name: component.name,
          type: component.component_type,
          gross_type: component.gross_type,
          rate: component.rate,
          flat_amount: component.flat_amount,
          amount: amount
        }
      end
    }
  end
  
  def get_components_for_role(role)
    plan = @deal.commission_plan
    return [] unless plan
    
    # Get all active components for this plan
    all_components = plan.commission_components.where(is_active: true)
    
    # Filter components by role
    # applies_to_role can be: 'primary_salesperson', 'sales_manager', 'finance_manager', 'desk_manager', 'secondary_salesperson', 'all_participants'
    # TEMPORARY: Treat NULL as primary_salesperson for backward compatibility
    if role == :primary_salesperson
      components = all_components.where(
        "applies_to_role IN (?) OR applies_to_role IS NULL",
        [role.to_s, 'all_participants']
      )
    else
      components = all_components.where(applies_to_role: [role.to_s, 'all_participants'])
    end
    
    # Special handling for secondary_salesperson (split deals)
    if role == :secondary_salesperson
      # Secondary gets a split of the primary's commission
      # Find components that apply to primary, then we'll split them
      components = all_components.where(
        "applies_to_role IN (?) OR applies_to_role IS NULL",
        ['primary_salesperson', 'all_participants']
      )
      # TODO: Apply split percentage (need to add split_percentage to deals or commission_components)
    end
    
    components.to_a
  end
  
  def calculate_total_for_components(components)
    total = 0.0
    
    components.each do |component|
      amount = calculate_component_amount(component)
      total += amount if amount > 0
    end
    
    total.round(2)
  end
  
  def can_generate?
    @deal.stage_is_won? &&
    @deal.commission_plan.present? &&
    @deal.primary_salesperson_id.present?
  end

  def generation_reasons
    reasons = []
    reasons << "Deal must be closed won" unless @deal.stage_is_won?
    reasons << "Deal must have a commission plan" unless @deal.commission_plan.present?
    reasons << "Deal must have a primary salesperson assigned" unless @deal.primary_salesperson_id.present?
    reasons
  end
  
  def calculate_component_amount(component)
    # Volume bonuses don't need a base amount
    if component.component_type == 'volume_bonus'
      # Return flat bonus amount (TODO: check if threshold met)
      return (component.flat_amount || 0).round(2)
    end
    
    # Flat per unit doesn't need gross calculation
    if component.component_type == 'flat_per_unit'
      # Return flat amount per unit (quantity is handled elsewhere if needed)
      return (component.flat_amount || 0).round(2)
    end
    
    # Get the base amount from the deal based on gross_type
    base_amount = case component.gross_type
                  when 'front', 'front_gross'
                    @deal.front_gross || 0
                  when 'commissionable_front', 'commissionable_front_gross'
                    @deal.commissionable_front_gross || 0
                  when 'back', 'back_gross'
                    @deal.back_gross || 0
                  when 'total', 'total_gross'
                    @deal.total_gross || 0
                  when 'addon', 'addon_gross'
                    @deal.addon_gross || 0
                  when 'selling_price'
                    @deal.selling_price || 0
                  else
                    0
                  end
    
    return 0 if base_amount <= 0
    
    # Calculate based on component_type
    amount = case component.component_type
             when 'percent_of_gross', 'percentage', 'addon_commission'
               # Percentage of gross
               base_amount * (component.rate || 0)
             else
               0
             end
    
    amount.round(2)
  end
  
  def build_calculation_details_for_role(role, components)
    plan = @deal.commission_plan
    
    {
      role: role.to_s,
      plan_name: plan&.name,
      plan_id: plan&.id,
      components: components.map do |component|
        amount = calculate_component_amount(component)
        
        {
          name: component.name,
          type: component.component_type,
          gross_type: component.gross_type,
          rate: component.rate,
          flat_amount: component.flat_amount,
          amount: amount
        }
      end
    }
  end
  
  def build_line_items_for_components(components)
    components.map do |component|
      amount = calculate_component_amount(component)
      
      {
        description: component.name,
        component_type: component.component_type,
        gross_type: component.gross_type,
        rate: component.rate,
        flat_amount: component.flat_amount,
        amount: amount
      }
    end
  end
  
  def build_deal_economics
    {
      selling_price: @deal.selling_price,
      unit_cost: @deal.unit_cost,
      front_gross: @deal.front_gross,
      commissionable_front_gross: @deal.commissionable_front_gross,
      back_gross: @deal.back_gross,
      total_gross: @deal.total_gross,
      addon_gross: @deal.addon_gross,
      pack_amount: @deal.effective_pack_amount,
      trade_allowance: @deal.trade_allowance,
      trade_payoff: @deal.trade_payoff,
      finance_reserve: @deal.finance_reserve,
      product_margin: @deal.product_margin
    }
  end
end
