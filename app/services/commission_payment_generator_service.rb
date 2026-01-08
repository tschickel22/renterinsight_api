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
    # Don't generate if payment already exists
    return nil if CommissionPayment.exists?(deal_id: @deal.id, is_deleted: [false, nil])
    
    # Don't generate if deal not closed won
    return nil unless @deal.stage == 'closed_won'
    
    # Don't generate if no salesperson
    return nil unless @deal.primary_salesperson_id.present?
    
    # Don't generate if deal has no commission plan
    return nil unless @deal.commission_plan.present?
    
    # Calculate commission amount
    commission_amount = calculate_commission_amount
    
    return nil if commission_amount <= 0
    
    # Build complete calculation details with line items and deal economics
    calculation_data = build_calculation_details
    calculation_data[:line_items] = build_line_items
    calculation_data[:deal_economics] = build_deal_economics
    
    # Create the payment
    payment = @deal.company.commission_payments.create!(
      deal_id: @deal.id,
      payee_user_id: @deal.primary_salesperson_id,
      amount: commission_amount,
      status: 'pending',
      location_id: @deal.location_id,
      calculation_details: calculation_data
    )
    
    payment
  end
  
  def preview
    commission_amount = calculate_commission_amount
    
    {
      can_generate: can_generate?,
      reasons: generation_reasons,
      estimated_amount: commission_amount,
      salesperson: @deal.primary_salesperson&.name,
      commission_plan: @deal.commission_plan&.name,
      calculation_details: build_calculation_details,
      line_items: build_line_items,
      deal_economics: build_deal_economics
    }
  end
  
  private
  
  def can_generate?
    @deal.stage == 'closed_won' &&
    @deal.primary_salesperson_id.present? &&
    @deal.commission_plan.present? &&
    !CommissionPayment.exists?(deal_id: @deal.id, is_deleted: [false, nil])
  end
  
  def generation_reasons
    reasons = []
    reasons << "Deal must be closed won" unless @deal.stage == 'closed_won'
    reasons << "Deal must have a salesperson assigned" unless @deal.primary_salesperson_id.present?
    reasons << "Deal must have a commission plan" unless @deal.commission_plan.present?
    reasons << "Payment already exists for this deal" if CommissionPayment.exists?(deal_id: @deal.id, is_deleted: [false, nil])
    reasons
  end
  
  def calculate_commission_amount
    plan = @deal.commission_plan
    return 0 unless plan
    
    # Get all active components for this plan
    components = plan.commission_components
                     .where(is_active: true)
    
    total_commission = 0.0
    
    components.each do |component|
      amount = calculate_component_amount(component)
      total_commission += amount if amount > 0
    end
    
    total_commission.round(2)
  end
  
  def calculate_component_amount(component)
    # Volume bonuses don't need a base amount
    if component.component_type == 'volume_bonus'
      # Return flat bonus amount (TODO: check if threshold met)
      return (component.flat_amount || 0).round(2)
    end
    
    # Get the base amount from the deal based on gross_type
    base_amount = case component.gross_type
                  when 'front_gross'
                    @deal.front_gross || 0
                  when 'commissionable_front'
                    @deal.commissionable_front_gross || 0
                  when 'back_gross'
                    @deal.back_gross || 0
                  when 'total_gross'
                    @deal.total_gross || 0
                  when 'addon_gross'
                    @deal.addon_gross || 0
                  when 'selling_price'
                    @deal.selling_price || 0
                  else
                    0
                  end
    
    return 0 if base_amount <= 0
    
    # Calculate based on component_type
    amount = case component.component_type
             when 'percentage'
               # Percentage of gross
               base_amount * (component.rate || 0)
             when 'flat_fee'
               # Fixed amount per deal
               component.flat_amount || 0
             else
               0
             end
    
    amount.round(2)
  end
  
  def build_calculation_details
    plan = @deal.commission_plan
    return {} unless plan
    
    components = plan.commission_components
                     .where(is_active: true)
    
    {
      plan_name: plan.name,
      plan_id: plan.id,
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
  
  def build_line_items
    plan = @deal.commission_plan
    return [] unless plan
    
    components = plan.commission_components
                     .where(is_active: true)
    
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
