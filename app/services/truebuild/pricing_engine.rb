# frozen_string_literal: true

module Truebuild
  # What a home costs a dealer and what they sell it for, with every number
  # traceable to the price book row or markup rule that produced it.
  #
  #   cost   = net base + required adders - program discount
  #            + option costs (most specific price row for this model)
  #            + freight (flat + per mile x miles from the plant)
  #   retail = each part marked up by the dealer's most specific rule;
  #            options with no dealer rule use the factory's suggested retail
  #
  # The breakdown includes cost. Only dealer staff may see it; anything a
  # buyer sees must come from #retail_only.
  class PricingEngine
    Result = Struct.new(:book, :variant, :lines, :totals, :warnings, keyword_init: true) do
      def to_h
        { book_id: book&.id, book_name: book&.name, variant_id: variant.id, model_number: variant.model_number,
          lines: lines, totals: totals, warnings: warnings }
      end

      # What a buyer may see: retail only, no cost, no rule detail.
      def retail_only
        { model_number: variant.model_number, total: totals[:retail],
          lines: lines.map { |l| l.slice(:kind, :label, :retail) } }
      end
    end

    def initialize(company:, variant:, option_ids: [], location: nil, construction: nil, book: nil)
      @company = company
      @variant = variant
      @option_ids = Array(option_ids).map(&:to_i).uniq
      @location = location
      @construction = construction
      @book = book || BookResolver.book_for(company, variant)
      @terms = DealerCatalogTerm.effective(company, variant.manufacturer_id)
      @rules = company.dealer_markup_rules.active.to_a
                      .select { |r| r.location_id.nil? || r.location_id == location&.id }
      @warnings = []
    end

    def call
      raise ArgumentError, 'No published price book covers this model' unless @book

      lines = [base_line, *option_lines, freight_line].compact
      totals = totals_for(lines)
      Result.new(book: @book, variant: @variant, lines: lines, totals: totals, warnings: @warnings)
    end

    private

    # ---- base ----------------------------------------------------------

    def base_line
      vp = @book.variant_prices.find_by(catalog_plan_variant_id: @variant.id)
      raise ArgumentError, "#{@variant.model_number} has no price in #{@book.name}" unless vp

      gross = vp.base_cost.to_d
      discount = (gross * @terms.program_discount_pct.to_d / 100).round(2)
      cost = gross - discount
      rule = rule_for(:base)
      retail = rule ? rule.apply(cost) : nil
      @warnings << 'No markup rule covers this home, so it has no retail price. Add a markup rule.' unless rule
      {
        kind: 'base', label: "#{@variant.catalog_plan.name} (#{@variant.model_number})",
        cost: money(cost), retail: money(retail),
        detail: { net_base_price: money(vp.net_base_price), required_adders: vp.required_adders,
                  program_discount: money(discount), rule: describe(rule) }
      }
    end

    # ---- options -------------------------------------------------------

    def option_lines
      return [] if @option_ids.empty?

      prices = @book.option_prices.where(catalog_option_id: @option_ids).includes(option: :group).to_a
      @option_ids.filter_map do |id|
        candidates = prices.select { |op| op.catalog_option_id == id && op.applies_to?(@variant, construction: @construction) }
        price = most_specific(candidates)
        unless price
          name = prices.find { |op| op.catalog_option_id == id }&.option&.name || "option #{id}"
          @warnings << "#{name} is not offered on #{@variant.model_number}."
          next
        end
        option_line(price)
      end
    end

    # A price for this exact model beats a size band beats a general price.
    def most_specific(candidates)
      candidates.max_by do |op|
        [op.catalog_plan_variant_id ? 1 : 0,
         [op.min_length_ft, op.max_length_ft, op.width_ft, op.section_type, op.construction, op.building_code, op.series].compact.size]
      end
    end

    def option_line(price)
      option = price.option
      if price.is_standard
        return { kind: 'option', option_id: option.id, label: option.name, group: option.group.name,
                 cost: 0.0, retail: 0.0, detail: { standard: true } }
      end

      cost = price.dealer_cost.to_d
      rule = rule_for(:option, option)
      retail, source =
        if rule then [rule.apply(cost), describe(rule)]
        elsif price.suggested_retail then [price.suggested_retail.to_d, "factory suggested retail"]
        else [cost, 'no markup']
        end
      { kind: 'option', option_id: option.id, label: option.name, group: option.group.name,
        cost: money(cost), retail: money(retail), detail: { rule: source, factory_code: option.factory_code } }
    end

    # ---- freight -------------------------------------------------------

    def freight_line
      flat = @terms.freight_flat.to_d
      per_mile = @terms.freight_per_mile.to_d
      miles = @terms.freight_miles.to_i
      return nil if flat.zero? && (per_mile.zero? || miles.zero?)

      @warnings << 'Freight per mile is set but miles from the plant are not.' if per_mile.positive? && miles.zero?
      cost = flat + (per_mile * miles)
      rule = rule_for(:freight)
      { kind: 'freight', label: 'Freight', cost: money(cost), retail: money(rule ? rule.apply(cost) : cost),
        detail: { flat: money(flat), per_mile: money(per_mile), miles: miles } }
    end

    # ---- totals --------------------------------------------------------

    def totals_for(lines)
      cost = lines.sum { |l| l[:cost].to_d }
      priced = lines.all? { |l| !l[:retail].nil? }
      retail = priced ? lines.sum { |l| l[:retail].to_d } : nil
      retail = round_retail(retail) if retail
      margin = retail && (retail - cost)
      margin_pct = retail && retail.positive? ? (margin / retail * 100).round(1) : nil
      if margin_pct && @terms.margin_floor_pct && margin_pct < @terms.margin_floor_pct.to_d
        @warnings << "Margin #{margin_pct}% is under your #{@terms.margin_floor_pct.to_d.to_s('F')}% floor."
      end
      { cost: money(cost), retail: money(retail), margin: money(margin), margin_pct: margin_pct&.to_f,
        rounded_to: @terms.round_retail_to }
    end

    def round_retail(amount)
      step = @terms.round_retail_to.to_i
      return amount unless step.positive?

      (amount / step).ceil * step
    end

    # ---- rules ---------------------------------------------------------

    # The most specific active rule for this part of the price.
    def rule_for(part, option = nil)
      applies = part == :option ? %w[options base_and_options] : %w[base base_and_options]
      plan = @variant.catalog_plan
      matching = @rules.select do |r|
        next false unless applies.include?(r.applies_to)

        case r.scope_type
        when 'all' then true
        when 'manufacturer' then r.manufacturer_id == @variant.manufacturer_id
        when 'series' then r.manufacturer_id == @variant.manufacturer_id && r.scope_value.to_s.casecmp?(plan.series.to_s)
        when 'plan' then part != :option && r.scope_id == plan.id
        when 'variant' then part != :option && r.scope_id == @variant.id
        when 'option_group' then option && r.scope_id == option.catalog_option_group_id
        when 'option' then option && r.scope_id == option.id
        end
      end
      # Freight is marked up only by a rule written for it (none yet), so it passes through at cost.
      return nil if part == :freight

      matching.max_by(&:rank)
    end

    def describe(rule)
      return nil unless rule

      value = rule.value.to_d
      how = case rule.markup_type
            when 'percent' then "#{value.to_s('F')}% over cost"
            when 'multiplier' then "#{value.to_s('F')} x cost"
            when 'flat' then "cost + #{money(value)}"
            when 'manual' then "set price #{money(value)}"
            end
      where = rule.location_id ? " at #{rule.location&.name}" : ''
      "#{rule.scope_type.tr('_', ' ')} rule: #{how}#{where}"
    end

    def money(value)
      value&.to_d&.round(2)&.to_f
    end
  end
end
