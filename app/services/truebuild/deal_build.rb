# frozen_string_literal: true

module Truebuild
  # Starts, edits and prices a deal's home build (DealHomeBuild). Every price
  # comes from PricingEngine, so a build, a buyer's design and the dealer's
  # price preview never disagree; the build adds what a rep needs on top:
  # quantities, TBD, N/C, a set retail on one line, and custom lines.
  #
  # Totals leave out TBD lines. N/C lines keep their cost (it still reduces
  # gross) and charge nothing.
  class DealBuild
    class Locked < StandardError; end

    def self.start(deal:, variant:, user: nil, vehicle: nil, design: nil)
      vehicle ||= deal.vehicle if deal.respond_to?(:vehicle) && deal.vehicle&.catalog_plan_variant_id == variant.id
      build = deal.company.deal_home_builds.create!(
        deal: deal, variant: variant, vehicle: vehicle, source: vehicle ? 'lot' : 'order', truebuild_design: design,
        location_id: deal.location_id || vehicle&.location_id, created_by: user
      )
      new(build).seed(design)
    end

    attr_reader :build, :warnings

    def initialize(build)
      @build = build
      @warnings = []
    end

    # The base home, freight and the dealer's always-included add-ons, plus
    # whatever the buyer chose when the build starts from their design.
    def seed(design = nil)
      result = engine(option_ids: design&.option_ids || [], addon_ids: design&.metadata.to_h['addon_ids'] || [])
      result&.lines.to_a.each do |l|
        case l[:kind]
        when 'base' then add_line(kind: 'base', label: l[:label], tax_category: 'home')
        when 'freight' then add_line(kind: 'freight', label: l[:label], tax_category: 'delivery')
        when 'option' then add_option_line(CatalogOption.find(l[:option_id]))
        # Quote-only add-ons are the rep's to add, not every build's.
        when 'addon'
          add_addon_line(@build.company.truebuild_addons.find(l[:addon_id])) unless l.dig(:detail, :mode) == 'quote_only'
        end
      end
      add_line(kind: 'base', label: base_label, tax_category: 'home') unless @build.lines.exists?(kind: 'base')
      reprice!
    end

    # ---- edits (each reprices) ------------------------------------------

    def add_option(option_id, quantity: 1)
      guard!
      option = CatalogOption.find(option_id)
      # One color per set: picking Clay siding replaces White.
      @build.lines.where(kind: 'option', catalog_option_id: alternatives(option).select(:id)).delete_all
      line = @build.lines.find_by(kind: 'option', catalog_option_id: option.id) || add_option_line(option)
      line.update!(quantity: quantity) if quantity.to_d != line.quantity
      reprice!
      line
    end

    def add_addon(addon_id)
      guard!
      addon = @build.company.truebuild_addons.find(addon_id)
      line = @build.lines.find_by(kind: 'addon', truebuild_addon_id: addon.id) || add_addon_line(addon)
      reprice!
      line
    end

    def add_custom(label:, unit_retail:, unit_cost: 0, quantity: 1, unit: 'each', tax_category: 'other', group_name: nil)
      guard!
      line = add_line(kind: 'custom', label: label, group_name: group_name, quantity: quantity, unit: unit, tax_category: tax_category,
                      unit_cost: unit_cost, unit_retail: unit_retail)
      reprice!
      line
    end

    # attrs: quantity, unit, tbd, no_charge, tax_category, notes; unit_retail
    # sets this line's price (kept through repricing until cleared with nil);
    # label, group_name and unit_cost only on custom lines.
    def update_line(line, attrs)
      guard!
      attrs = attrs.to_h.symbolize_keys
      changes = attrs.slice(:quantity, :unit, :tbd, :no_charge, :tax_category)
      changes.merge!(attrs.slice(:label, :group_name, :unit_cost)) if line.kind == 'custom'
      meta = line.metadata.to_h
      meta['notes'] = attrs[:notes] if attrs.key?(:notes)
      if attrs.key?(:unit_retail)
        changes[:unit_retail] = attrs[:unit_retail]
        line.kind == 'custom' || attrs[:unit_retail].nil? ? meta.delete('set_retail') : meta['set_retail'] = true
      end
      line.update!(changes.merge(metadata: meta))
      reprice!
      line
    end

    def remove_line(line)
      guard!
      raise ArgumentError, 'The home itself cannot be removed; change the model instead' if line.kind == 'base'

      line.destroy!
      reprice!
    end

    # ---- pricing --------------------------------------------------------

    def reprice!
      guard!
      lines = @build.lines.reload.to_a
      result = engine(option_ids: lines.filter_map(&:catalog_option_id), addon_ids: lines.filter_map(&:truebuild_addon_id))
      priced = index(result)
      lines.each { |line| price_line(line, priced) }
      @build.update!(price_book: result&.book, cost_book: result&.cost_book, options_book: result&.options_book,
                     priced_at: Time.current, totals: totals_for(@build.lines.reload.to_a))
      self
    end

    private

    def guard!
      raise Locked, 'This build is locked by a signed agreement; change it with a change order' if @build.locked?
    end

    def engine(option_ids:, addon_ids:)
      result = PricingEngine.new(company: @build.company, variant: @build.variant, option_ids: option_ids, addon_ids: addon_ids,
                                 location: @build.location, construction: @build.construction, quote: true).call
      # The engine's margin check is for its own sum; the build checks its own totals.
      @warnings = result.warnings.reject { |w| w.start_with?('Margin ') || w.include?(' is not offered on ') }
      result
    rescue ArgumentError => e
      @warnings = [e.message]
      nil
    end

    def index(result)
      lines = result&.lines.to_a
      { base: lines.find { |l| l[:kind] == 'base' }, freight: lines.find { |l| l[:kind] == 'freight' },
        options: lines.select { |l| l[:kind] == 'option' }.index_by { |l| l[:option_id] },
        addons: lines.select { |l| l[:kind] == 'addon' }.index_by { |l| l[:addon_id] } }
    end

    def price_line(line, priced)
      source = case line.kind
               when 'base' then priced[:base]
               when 'freight' then priced[:freight]
               when 'option' then priced[:options][line.catalog_option_id]
               when 'addon' then priced[:addons][line.truebuild_addon_id]
               end
      meta = line.metadata.to_h
      if line.kind == 'custom'
        meta.delete('not_offered')
      elsif source
        meta.delete('not_offered')
        meta['rule'] = source.dig(:detail, :rule)
        line.unit_cost = source[:cost]
        line.unit_retail = source[:retail] unless meta['set_retail']
        line.is_standard = source.dig(:detail, :standard) == true if line.kind == 'option'
      else
        # Priced before, not offered now (a new book dropped it): keep the
        # last price, flag it for the rep.
        meta['not_offered'] = true
        @warnings << "#{line.label} is not offered on #{@build.variant.model_number} in the current price book."
      end
      qty = line.quantity.to_d
      line.cost = line.unit_cost && (line.unit_cost.to_d * qty).round(2)
      line.retail = if line.no_charge then 0
                    elsif line.unit_retail then (line.unit_retail.to_d * qty).round(2)
                    end
      line.metadata = meta
      line.save! if line.changed?
    end

    def totals_for(lines)
      counted = lines.select(&:priced?)
      cost = counted.sum { |l| l.cost.to_d }
      retail = counted.all? { |l| !l.retail.nil? } ? counted.sum { |l| l.retail.to_d } : nil
      terms = DealerCatalogTerm.effective(@build.company, @build.variant.manufacturer_id)
      retail = PricingEngine.round_retail(retail, terms) if retail
      margin = retail && (retail - cost)
      margin_pct = retail&.positive? ? (margin / retail * 100).round(1) : nil
      if margin_pct && terms.margin_floor_pct && margin_pct < terms.margin_floor_pct.to_d
        @warnings << "Margin #{margin_pct}% is under your #{terms.margin_floor_pct.to_d.to_s('F')}% floor."
      end
      unpriced = counted.select { |l| l.retail.nil? }.map(&:label)
      @warnings << "No retail price yet for #{unpriced.to_sentence}." if unpriced.any?
      { cost: cost.round(2).to_f, retail: retail&.round(2)&.to_f, margin: margin&.round(2)&.to_f, margin_pct: margin_pct&.to_f,
        tbd_count: lines.count(&:tbd), rounded_to: terms.round_retail_to, warnings: @warnings.uniq }
    end

    # The options this one replaces: the others in its color set ("Siding"),
    # or in its group when the group is single-choice.
    def alternatives(option)
      others = CatalogOption.where(manufacturer_id: option.manufacturer_id).where.not(id: option.id)
      set = option.metadata.to_h['color_set'].presence
      return others.where(catalog_option_group_id: option.catalog_option_group_id) if option.group&.selection_type == 'single'
      return others.where(catalog_option_group_id: option.catalog_option_group_id).where("metadata->>'color_set' = ?", set) if set

      CatalogOption.none
    end

    def add_line(**attrs)
      @build.lines.create!(position: next_position, **attrs)
    end

    def add_option_line(option)
      add_line(kind: 'option', option: option, label: option.name, group_name: option.group&.name, factory_code: option.factory_code,
               unit: DealHomeBuildLine.unit_for(option.name), tax_category: 'factory_option')
    end

    def add_addon_line(addon)
      add_line(kind: 'addon', truebuild_addon: addon, label: addon.name, group_name: 'Dealer add-ons',
               tax_category: addon_tax_category(addon))
    end

    # Delivery, set-up and utility hookups are taxed apart in some states (E45).
    def addon_tax_category(addon)
      name = addon.name.to_s.downcase
      return 'delivery' if name.match?(/deliver|transport|freight|escort/)
      return 'setup' if name.match?(/set[\s-]?up|block|level|anchor|skirt|install/)
      return 'utility_connection' if name.match?(/utilit|hook[\s-]?up|connect|septic|well|electric|plumb/)
      return 'fee' if addon.fee?

      'other'
    end

    def base_label
      "#{@build.variant.catalog_plan.name} (#{@build.variant.model_number})"
    end

    def next_position
      @build.lines.maximum(:position).to_i + 1
    end
  end
end
