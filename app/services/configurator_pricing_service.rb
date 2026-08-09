# frozen_string_literal: true

class ConfiguratorPricingService
  def self.calculate_for_company(floor_plan, company, selected_option_ids = [])
    company_floor_plan = company.company_floor_plans.find_by(floor_plan: floor_plan)

    base_price = calculate_base_price(floor_plan, company_floor_plan)
    options_result = calculate_options_total(selected_option_ids, company, floor_plan)

    {
      base_price: floor_plan.net_price || base_price[:low],
      base_price_low: base_price[:low],
      base_price_high: base_price[:high],
      options_total: options_result[:dealer_total],
      options_total_low: options_result[:low],
      options_total_high: options_result[:high],
      total_dealer: base_price[:low] + options_result[:dealer_total],
      total_retail: base_price[:high] + options_result[:retail_total],
      total_price_low: base_price[:low] + options_result[:low],
      total_price_high: base_price[:high] + options_result[:high],
      price_range_low: base_price[:low] + options_result[:low],
      price_range_high: base_price[:high] + options_result[:high],
      has_fixed_pricing: base_price[:fixed] && options_result[:fixed],
      show_contact_for_quote: true,
      selected_options: options_result[:selected_options]
    }
  end

  # Public entry point for callers that only need the base price range, without
  # the option maths. Controllers used to inline this as
  # `company_floor_plan.base_price_low || floor_plan.base_price_low`, but
  # CompanyFloorPlan has no base_price_* columns (it carries dealer_cost,
  # retail_price and a markup), so that raised NoMethodError as soon as a dealer
  # actually had a floor plan mapped. Route every caller through here instead.
  #
  # @return [Hash] { low:, high:, fixed: }
  def self.base_price_for(floor_plan, company_floor_plan)
    calculate_base_price(floor_plan, company_floor_plan)
  end

  private_class_method def self.calculate_base_price(floor_plan, company_floor_plan)
    if company_floor_plan&.retail_price.present?
      {
        low: company_floor_plan.retail_price,
        high: company_floor_plan.retail_price,
        fixed: true
      }
    elsif company_floor_plan&.dealer_cost.present?
      {
        low: company_floor_plan.dealer_cost,
        high: company_floor_plan.retail_price || company_floor_plan.dealer_cost,
        fixed: company_floor_plan.dealer_cost == company_floor_plan.retail_price
      }
    elsif company_floor_plan&.markup_type.present?
      apply_markup(floor_plan, company_floor_plan)
    elsif floor_plan.net_price.present?
      {
        low: floor_plan.net_price,
        high: floor_plan.suggested_retail_high || floor_plan.net_price,
        fixed: false
      }
    else
      {
        low: floor_plan.suggested_retail_low || 0,
        high: floor_plan.suggested_retail_high || 0,
        fixed: false
      }
    end
  end

  private_class_method def self.apply_markup(floor_plan, company_floor_plan)
    base_low = company_floor_plan.dealer_cost || floor_plan.base_price_low || 0
    base_high = floor_plan.base_price_high || 0
    markup = company_floor_plan.markup_value || 0

    case company_floor_plan.markup_type
    when 'percentage'
      multiplier = 1 + (markup / 100.0)
      {
        low: (base_low * multiplier).round(2),
        high: (base_high * multiplier).round(2),
        fixed: false
      }
    when 'fixed_dollar'
      {
        low: base_low + markup,
        high: base_high + markup,
        fixed: false
      }
    else
      {
        low: floor_plan.suggested_retail_low || 0,
        high: floor_plan.suggested_retail_high || 0,
        fixed: false
      }
    end
  end

  private_class_method def self.calculate_options_total(selected_option_ids, company, floor_plan = nil)
    empty = { low: 0, high: 0, dealer_total: 0, retail_total: 0, fixed: true, selected_options: [] }
    return empty if selected_option_ids.blank?

    options = FloorPlanOption.where(id: selected_option_ids)

    total_low = 0
    total_high = 0
    dealer_total = 0
    retail_total = 0
    all_fixed = true
    selected_options = []

    options.each do |option|
      # Check model-specific applicability overrides first
      applicability = if floor_plan
        FloorPlanOptionApplicability.find_by(floor_plan_id: floor_plan.id, floor_plan_option_id: option.id)
      end

      # Then company overrides
      override = company.company_floor_plan_option_overrides.find_by(floor_plan_option: option)

      dealer_price = applicability&.price_dealer_override || option.price_dealer
      retail_price = applicability&.price_retail_override || option.price_retail

      if override&.retail_price.present?
        total_low += override.retail_price
        total_high += override.retail_price
        dealer_total += override.dealer_cost || override.retail_price
        retail_total += override.retail_price
      elsif dealer_price.present? || retail_price.present?
        d = dealer_price || 0
        r = retail_price || dealer_price || 0
        total_low += d
        total_high += r
        dealer_total += d
        retail_total += r
        all_fixed = false if d != r
      else
        total_low += option.price_impact_low || 0
        total_high += option.price_impact_high || 0
        dealer_total += option.price_impact_low || 0
        retail_total += option.price_impact_high || 0
        all_fixed = false if option.price_impact_low != option.price_impact_high
      end

      selected_options << {
        id: option.id,
        name: option.name,
        option_code: option.option_code,
        price_dealer: dealer_price,
        price_retail: retail_price,
        price_impact_low: option.price_impact_low,
        price_impact_high: option.price_impact_high
      }
    end

    {
      low: total_low,
      high: total_high,
      dealer_total: dealer_total,
      retail_total: retail_total,
      fixed: all_fixed,
      selected_options: selected_options
    }
  end
end
