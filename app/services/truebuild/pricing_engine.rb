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
    # book: where retail comes from (the book the dealer accepted).
    # cost_book: where cost comes from (always the plant's current book).
    Result = Struct.new(:book, :cost_book, :variant, :lines, :totals, :warnings, keyword_init: true) do
      def to_h
        { book_id: book&.id, book_name: book&.name, cost_book_id: cost_book&.id, cost_book_name: cost_book&.name,
          variant_id: variant.id, model_number: variant.model_number, lines: lines, totals: totals, warnings: warnings }
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
      # Cost always follows the factory's current book: that is what the
      # factory invoices. A dealer holding a new book for review keeps their
      # retail, marked up from the book they accepted, until they accept it.
      # An explicit book prices both from that book.
      @book = book || BookResolver.book_for(company, variant)
      @cost_book = book || BookResolver.current_for(variant) || @book
      @terms = DealerCatalogTerm.effective(company, variant.manufacturer_id)
      @rules = company.dealer_markup_rules.active.to_a
                      .select { |r| r.location_id.nil? || r.location_id == location&.id }
      @warnings = []
    end

    def call
      raise ArgumentError, 'No published price book covers this model' unless @book

      if @cost_book != @book
        @warnings << "Your prices are still based on #{@book.name}, but costs follow #{@cost_book.name}. " \
                     'Review the new price book to update your prices.'
      end
      lines = [base_line, *option_lines, freight_line].compact
      totals = totals_for(lines)
      Result.new(book: @book, cost_book: @cost_book, variant: @variant, lines: lines, totals: totals, warnings: @warnings)
    end

    private

    # ---- base ----------------------------------------------------------

    def base_line
      vp = @cost_book.variant_prices.find_by(catalog_plan_variant_id: @variant.id)
      raise ArgumentError, "#{@variant.model_number} has no price in #{@cost_book.name}" unless vp

      gross = vp.base_cost.to_d
      discount = (gross * @terms.program_discount_pct.to_d / 100).round(2)
      cost = gross - discount
      rule = rule_for(:base)
      retail = rule ? rule.apply(retail_basis(vp) || cost) : nil
      @warnings << 'No markup rule covers this home, so it has no retail price. Add a markup rule.' unless rule
      {
        kind: 'base', label: "#{@variant.catalog_plan.name} (#{@variant.model_number})",
        cost: money(cost), retail: money(retail),
        detail: { net_base_price: money(vp.net_base_price), required_adders: vp.required_adders,
                  program_discount: money(discount), rule: describe(rule) }
      }
    end

    # ---- options -------------------------------------------------------

    # The accepted book's cost for this home, less the same program
    # discount: what the dealer's retail is marked up from while they hold a
    # new book for review. Nil when both books are the same.
    def retail_basis(cost_vp)
      return nil if @book == @cost_book

      vp = @book.variant_prices.find_by(catalog_plan_variant_id: @variant.id) || cost_vp
      gross = vp.base_cost.to_d
      gross - (gross * @terms.program_discount_pct.to_d / 100).round(2)
    end

    def option_lines
      return [] if @option_ids.empty?

      prices = offered(@cost_book)
      retail_prices = @book == @cost_book ? prices : offered(@book)
      @option_ids.filter_map do |id|
        price = most_specific(prices.select { |op| op.catalog_option_id == id })
        unless price
          name = CatalogOption.find_by(id: id)&.name || "option #{id}"
          @warnings << "#{name} is not offered on #{@variant.model_number}."
          next
        end
        option_line(price, most_specific(retail_prices.select { |op| op.catalog_option_id == id }) || price)
      end
    end

    def offered(book)
      book.option_prices.where(catalog_option_id: @option_ids).includes(option: :group).to_a
          .select { |op| op.applies_to?(@variant, construction: @construction) }
    end

    # A price for this exact model beats a size band beats a general price.
    def most_specific(candidates)
      candidates.max_by do |op|
        [op.catalog_plan_variant_id ? 1 : 0,
         [op.min_length_ft, op.max_length_ft, op.width_ft, op.section_type, op.construction, op.building_code, op.series].compact.size]
      end
    end

    # price: the current book's row (cost). retail_price: the accepted
    # book's row, which the retail is built from.
    def option_line(price, retail_price = price)
      option = price.option
      if price.is_standard
        return { kind: 'option', option_id: option.id, label: option.name, group: option.group.name,
                 cost: 0.0, retail: 0.0, detail: { standard: true } }
      end

      cost = price.dealer_cost.to_d
      basis = retail_price.is_standard ? cost : retail_price.dealer_cost.to_d
      rule = rule_for(:option, option)
      retail, source =
        if rule then [rule.apply(basis), describe(rule)]
        elsif retail_price.suggested_retail then [retail_price.suggested_retail.to_d, "factory suggested retail"]
        else [basis, 'no markup']
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
      number = value.frac.zero? ? value.to_i.to_s : value.to_s('F')
      how = case rule.markup_type
            when 'percent' then "#{number}% over cost"
            when 'multiplier' then "#{number} x cost"
            when 'flat' then "cost + #{ActiveSupport::NumberHelper.number_to_currency(value, precision: value.frac.zero? ? 0 : 2)}"
            when 'manual' then "set price #{ActiveSupport::NumberHelper.number_to_currency(value, precision: value.frac.zero? ? 0 : 2)}"
            end
      where = rule.location_id ? " at #{rule.location&.name}" : ''
      "#{SCOPE_WORDS[rule.scope_type]} rule: #{how}#{where}"
    end

    SCOPE_WORDS = { 'all' => 'Every home', 'manufacturer' => 'Manufacturer', 'series' => 'Series', 'plan' => 'Plan',
                    'variant' => 'Model', 'option_group' => 'Option group', 'option' => 'Option' }.freeze

    def money(value)
      value&.to_d&.round(2)&.to_f
    end
  end
end
