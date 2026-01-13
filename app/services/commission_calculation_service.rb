# frozen_string_literal: true

# CommissionCalculationService
# 
# Calculates commission owed based on deal economics and active commission components.
# 
# Usage:
#   service = CommissionCalculationService.new(deal, user)
#   result = service.calculate
#   # => { deal_id: 123, payee_user_id: 45, total_commission: 3250.00, line_items: [...] }

class CommissionCalculationService
  attr_reader :deal, :user, :company
  
  def initialize(deal, user = nil)
    @deal = deal
    @user = user || deal.primary_salesperson
    @company = deal.company
    
    unless @user.present?
      Rails.logger.warn "[CommissionCalculationService] No user provided for deal #{deal.id}"
    end
  end
  
  # Calculate commission for the user on this deal
  # Returns hash with total and line items
  def calculate
    return empty_result unless @user.present?
    
    components = applicable_components
    
    line_items = components.map do |component|
      calculate_component(component)
    end.compact
    
    {
      deal_id: @deal.id,
      payee_user_id: @user.id,
      payee_name: @user.name,
      total_commission: line_items.sum { |item| item[:amount] }.round(2),
      line_items: line_items,
      deal_economics: deal_economics_summary
    }
  end
  
  private
  
  # Get components that apply to this deal and user
  def applicable_components
    # Get active components for company/location
    components = @company.commission_components
      .active
      .for_role(@user.role || 'salesperson')
      .for_location(@deal.location_id)
      .ordered
    
    # Filter by deal-specific criteria
    components.select do |component|
      component.applies_to_deal?(@deal)
    end
  end
  
  # Calculate a single component's commission amount
  def calculate_component(component)
    amount = case component.component_type
    when 'percent_of_gross'
      calculate_percent_of_gross(component)
    when 'flat_per_unit'
      calculate_flat_per_unit(component)
    when 'monthly_bonus'
      calculate_monthly_bonus(component)
    when 'addon_commission'
      calculate_addon_commission(component)
    else
      0
    end
    
    return nil if amount <= 0
    
    {
      component_id: component.id,
      component_name: component.name,
      component_type: component.component_type,
      amount: amount.round(2),
      calculation_notes: build_calculation_notes(component, amount)
    }
  end
  
  # Calculate percentage of gross
  def calculate_percent_of_gross(component)
    gross_amount = case component.gross_type
    when 'front' then @deal.front_gross
    when 'back' then @deal.back_gross
    when 'total' then @deal.total_gross
    when 'commissionable_front' then @deal.commissionable_front_gross
    when 'addon' then @deal.addon_gross
    else 0
    end
    
    (gross_amount * component.rate).round(2)
  end
  
  # Calculate flat amount per unit
  def calculate_flat_per_unit(component)
    units = @deal.quantity || 1
    (component.flat_amount * units).round(2)
  end
  
  # Calculate monthly/quarterly bonus
  def calculate_monthly_bonus(component)
    return 0 unless component.threshold_period == 'monthly'
    
    # Count delivered units this month for this user
    start_of_month = Date.today.beginning_of_month
    end_of_month = Date.today.end_of_month
    
    units_this_month = Deal
      .where(company_id: @company.id)
      .where(primary_salesperson_id: @user.id)
      .where(stage: 'closed_won')
      .where('delivery_date >= ? AND delivery_date <= ?', start_of_month, end_of_month)
      .sum(:quantity)
    
    units_this_month >= component.units_threshold ? component.flat_amount : 0
  end
  
  # Calculate commission on add-ons (MH-specific)
  def calculate_addon_commission(component)
    (@deal.addon_gross * (component.rate || 0)).round(2)
  end
  
  # Build human-readable calculation notes
  def build_calculation_notes(component, amount)
    case component.component_type
    when 'percent_of_gross'
      gross = @deal.send("#{component.gross_type}_gross")
      "#{(component.rate * 100).round(2)}% of $#{gross.round(2)} #{component.gross_type.humanize} gross"
    when 'flat_per_unit'
      "$#{component.flat_amount} × #{@deal.quantity || 1} units"
    when 'monthly_bonus'
      units = calculate_units_this_month
      "Monthly bonus (#{units} units ≥ #{component.units_threshold} threshold)"
    when 'addon_commission'
      "#{(component.rate * 100).round(2)}% of $#{@deal.addon_gross.round(2)} add-ons"
    else
      "#{component.component_type.humanize}: $#{amount.round(2)}"
    end
  end
  
  # Helper to get units count for current month
  def calculate_units_this_month
    start_of_month = Date.today.beginning_of_month
    end_of_month = Date.today.end_of_month
    
    Deal
      .where(company_id: @company.id)
      .where(primary_salesperson_id: @user.id)
      .where(stage: 'closed_won')
      .where('delivery_date >= ? AND delivery_date <= ?', start_of_month, end_of_month)
      .sum(:quantity)
  end
  
  # Summary of deal economics for audit trail
  def deal_economics_summary
    {
      selling_price: @deal.selling_price,
      unit_cost: @deal.unit_cost,
      front_gross: @deal.front_gross,
      pack: @deal.effective_pack_amount,
      commissionable_front_gross: @deal.commissionable_front_gross,
      back_gross: @deal.back_gross,
      total_gross: @deal.total_gross,
      addon_gross: @deal.addon_gross,
      quantity: @deal.quantity || 1
    }
  end
  
  # Empty result when no user
  def empty_result
    {
      deal_id: @deal.id,
      payee_user_id: nil,
      payee_name: nil,
      total_commission: 0,
      line_items: [],
      deal_economics: deal_economics_summary
    }
  end
end
