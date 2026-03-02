# frozen_string_literal: true

class ConfiguratorPricingService
  def self.calculate_for_company(floor_plan, company, selected_option_ids = [])
    company_floor_plan = company.company_floor_plans.find_by(floor_plan: floor_plan)

    base_price = calculate_base_price(floor_plan, company_floor_plan)
    options_total = calculate_options_total(selected_option_ids, company)

    {
      base_price_low: base_price[:low],
      base_price_high: base_price[:high],
      options_total_low: options_total[:low],
      options_total_high: options_total[:high],
      total_price_low: base_price[:low] + options_total[:low],
      total_price_high: base_price[:high] + options_total[:high],
      has_fixed_pricing: base_price[:fixed] && options_total[:fixed],
      show_contact_for_quote: true
    }
  end

  private_class_method def self.calculate_base_price(floor_plan, company_floor_plan)
    if company_floor_plan&.retail_price.present?
      {
        low: company_floor_plan.retail_price,
        high: company_floor_plan.retail_price,
        fixed: true
      }
    elsif company_floor_plan&.markup_type.present?
      apply_markup(floor_plan, company_floor_plan)
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

  private_class_method def self.calculate_options_total(selected_option_ids, company)
    return { low: 0, high: 0, fixed: true } if selected_option_ids.blank?

    options = FloorPlanOption.where(id: selected_option_ids)

    total_low = 0
    total_high = 0
    all_fixed = true

    options.each do |option|
      override = company.company_floor_plan_option_overrides.find_by(floor_plan_option: option)

      if override&.retail_price.present?
        total_low += override.retail_price
        total_high += override.retail_price
      else
        total_low += option.price_impact_low || 0
        total_high += option.price_impact_high || 0
        all_fixed = false if option.price_impact_low != option.price_impact_high
      end
    end

    {
      low: total_low,
      high: total_high,
      fixed: all_fixed
    }
  end
end
