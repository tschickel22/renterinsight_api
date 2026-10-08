# frozen_string_literal: true

module Truebuild
  # Starts, edits and prices a deal's home build (DealHomeBuild). Every price
  # comes from PricingEngine, so a build, a buyer's design and the dealer's
  # price preview never disagree; the build adds what a rep needs on top:
  # quantities, TBD, N/C, a set retail on one line, and custom lines.
  #
  # Totals leave out TBD lines. N/C lines keep their cost (it still reduces
  # gross) and charge nothing.
  #
  # The build is the deal sheet, so it writes the deal: one home line (base,
  # factory options and freight, less the buyer discounts), a deal product for
  # each add-on, template and custom line, and the deal's discount columns that
  # agreements merge. Those deal products carry a deal_sheet:<id> tag in their
  # notes, which survives the Products form's delete-and-recreate save, so a
  # line is never entered twice in Products, the deal sheet and the Deal Desk.
  #
  # It works the other way too (take_products!): a line added in Products
  # becomes a sheet line, and changing or removing a sheet line's deal
  # product there changes or removes the sheet line. The home line is the
  # sheet's alone: its price comes from the price book and the options.
  #
  # A deal can hold several versions of the sheet. Only the LIVE version
  # writes the deal; the others are drafts the rep prices beside it and can
  # make live, which rewrites the deal from that version.
  class DealBuild
    class Locked < StandardError; end

    TAG = /deal_sheet:(\w+)/
    # The lines written to the deal as lines of their own (the rest roll into the home line).
    EXTRA_KINDS = %w[addon template custom].freeze
    # Bumped when totals gain or change a figure: an older sheet reprices when opened.
    TOTALS_VERSION = 5

    # Priced before the deal's lines last changed (a Products save), or by an
    # older version of these totals.
    def self.stale?(build)
      return false if build.locked?
      return true if build.priced_at.nil? || build.totals.to_h['version'] != TOTALS_VERSION
      # A platform admin corrected one of its books since (Truebuild::PriceCorrector).
      books = [build.price_book, build.cost_book, build.options_book].compact.uniq
      return true if books.any? { |b| (at = b.metadata.to_h['corrected_at']).present? && Time.zone.parse(at) > build.priced_at }

      changed = build.deal.deal_products.maximum(:updated_at)
      changed.present? && changed > build.priced_at + 1.second
    end
    # Factory Direct's ladder: sale and dealer savings are percents of the
    # home's MSRP, preferred payment a percent of the price after them, other
    # a dollar amount.
    DISCOUNTS = { 'savings_pct' => :dealer_savings_pct, 'sale_pct' => :sale_discount_pct,
                  'preferred_pct' => :preferred_payment_pct }.freeze

    # The deal's first build is LIVE; a later one is a draft version unless
    # live: true.
    def self.start(deal:, variant:, user: nil, vehicle: nil, design: nil, live: nil, label: nil)
      vehicle ||= deal.vehicle if deal.respond_to?(:vehicle) && deal.vehicle&.catalog_plan_variant_id == variant.id
      terms = DealerCatalogTerm.effective(deal.company, variant.manufacturer_id)
      discounts = DISCOUNTS.transform_values { |field| terms[field]&.to_f || 0.0 }.merge('other_amount' => 0.0)
      first = !deal.home_builds.exists?
      build = deal.company.deal_home_builds.create!(
        deal: deal, variant: variant, vehicle: vehicle, source: vehicle ? 'lot' : 'order', truebuild_design: design,
        location_id: deal.location_id || vehicle&.location_id, created_by: user, discounts: discounts,
        version_number: next_version(deal), label: label.presence, live: first
      )
      service = new(build).seed(design)
      service.make_live! if live && !first
      service
    end

    def self.next_version(deal)
      deal.home_builds.maximum(:version_number).to_i + 1
    end

    # The one-of set an option belongs to: a color set ("Siding"), or a
    # standard choice written as an option, "Shutters: Black" (the buyer
    # designer reads these the same way, BuyerCatalog::NAMED_CHOICE).
    def self.choice_set(option)
      option.metadata.to_h['color_set'].presence ||
        (option.kind == 'standard' && option.name.to_s[BuyerCatalog::NAMED_CHOICE, 1]&.strip) || nil
    end

    # A line's name: a color or finish pick carries its set ("Shutters:
    # Blue"), since "Blue" alone says nothing on a sheet, quote or PO.
    def self.option_label(option)
      set = choice_set(option)
      name = option.name.to_s
      set && !name.downcase.start_with?(set.downcase) ? "#{set}: #{name}" : name
    end

    attr_reader :build, :warnings

    # A new draft version with this one's home, lines, freight and discounts.
    def copy(label: nil, user: nil)
      copy = nil
      DealHomeBuild.transaction do
        copy = @build.dup
        copy.assign_attributes(version_number: self.class.next_version(@build.deal), label: label.presence, live: false,
                               status: 'draft', created_by: user || @build.created_by, priced_at: nil)
        copy.save!
        @build.lines.each { |l| copy.lines.create!(l.attributes.except('id', 'deal_home_build_id', 'created_at', 'updated_at')) }
      end
      self.class.new(copy).reprice!
    end

    # Makes this version the one the deal is written from. The version it
    # replaces stays as a draft. Refused while the LIVE version is signed.
    def make_live!
      return reprice! if @build.live?

      current = @build.deal.home_build
      raise Locked, "#{current.version_name} is locked by a signed agreement; change it with a change order" if current&.locked?

      DealHomeBuild.transaction do
        current&.update!(live: false)
        @build.update!(live: true)
      end
      reprice!
    end

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
        when 'freight' then add_line(kind: 'freight', label: l[:label], tax_category: 'delivery') unless @build.source == 'lot'
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

    # A line from the dealer's fee or package templates, the same ones the
    # Products tab and the Deal Desk offer. Priced as the template sets it.
    def add_template(type, id)
      guard!
      template = case type.to_s
                 when 'FeeTemplate' then @build.company.fee_templates.find(id)
                 when 'PackageTemplate' then @build.company.package_templates.find(id)
                 else raise ArgumentError, 'Unknown template type'
                 end
      line = @build.lines.find_by(kind: 'template', source_template: template) ||
             add_line(kind: 'template', source_template: template, label: template.name,
                      group_name: template.is_a?(FeeTemplate) ? 'Fees' : 'Packages',
                      unit_retail: template.is_a?(FeeTemplate) ? template.default_amount : template.default_price,
                      unit_cost: template.try(:cost) || 0, tax_category: template_tax_category(template))
      reprice!
      line
    end

    # Miles from the plant to the homesite; nil goes back to the estimate.
    def set_freight_miles(miles)
      guard!
      @build.update!(freight_miles: miles.presence&.to_i, freight_miles_set: miles.present?)
      reprice!
    end

    # { savings_pct:, sale_pct:, preferred_pct:, other_amount: }
    def set_discounts(attrs)
      guard!
      allowed = attrs.to_h.stringify_keys.slice(*DISCOUNTS.keys, 'other_amount').transform_values { |v| v.to_d.round(4).to_f }
      @build.update!(discounts: @build.discounts.to_h.merge(allowed))
      reprice!
    end

    def add_custom(label:, unit_retail:, unit_cost: 0, quantity: 1, unit: 'each', tax_category: 'other', group_name: nil)
      guard!
      line = add_line(kind: 'custom', label: label, group_name: group_name, quantity: quantity, unit: unit, tax_category: tax_category,
                      unit_cost: unit_cost, unit_retail: unit_retail)
      reprice!
      line
    end

    # attrs: quantity, unit, tbd, no_charge, tax_category, notes; unit_retail
    # and unit_cost set this line's price and cost (kept through repricing
    # until cleared with nil); label and group_name only on custom and
    # template lines.
    def update_line(line, attrs)
      guard!
      attrs = attrs.to_h.symbolize_keys
      changes = attrs.slice(:quantity, :unit, :tbd, :no_charge, :tax_category)
      # TBD (no price yet) and N/C (no charge) cannot both be true: setting one clears the other.
      changes[:no_charge] = false if ActiveModel::Type::Boolean.new.cast(changes[:tbd])
      changes[:tbd] = false if ActiveModel::Type::Boolean.new.cast(changes[:no_charge])
      changes.merge!(attrs.slice(:label, :group_name, :unit_cost)) if %w[custom template].include?(line.kind)
      # A book line's cost is the book's; the rep can set what it really costs (the hauler's bill for
      # freight, a factory quote for an option), kept through repricing until cleared with nil.
      if !%w[custom template].include?(line.kind) && attrs.key?(:unit_cost)
        changes[:unit_cost] = attrs[:unit_cost]
        attrs[:unit_cost].nil? ? line.metadata.delete('set_cost') : line.metadata['set_cost'] = true
      end
      meta = line.metadata.to_h
      meta['notes'] = attrs[:notes] if attrs.key?(:notes)
      if attrs.key?(:unit_retail)
        changes[:unit_retail] = attrs[:unit_retail]
        %w[custom template].include?(line.kind) || attrs[:unit_retail].nil? ? meta.delete('set_retail') : meta['set_retail'] = true
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

    # Brings what a Products save changed back onto the LIVE sheet, then
    # reprices (which rewrites the deal). Called after Products creates or
    # saves lines, never after a delete: the Products form deletes every line
    # before recreating the list, so a sheet line whose deal product is gone
    # after a save was removed there.
    def take_products!
      return self unless @build.live?
      return reprice! if @build.deal.cost_snapshotted?

      guard!
      products = @build.deal.deal_products.reload.to_a
      by_tag = products.group_by { |dp| tag_of(dp) }
      DealHomeBuildLine.transaction do
        @build.lines.reload.select { |l| EXTRA_KINDS.include?(l.kind) && l.priced? }.each do |line|
          dp = by_tag[line.id.to_s]&.first
          dp ? take_edits(line, dp) : line.destroy!
        end
        products.each { |dp| adopt(dp) if tag_of(dp).nil? && !dp.home_line_item? }
      end
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
      sync_deal!
      self
    end

    # Writes the deal from the build (see the class comment). Skipped once the
    # deal is won or posted to the GL: its price and cost are frozen then.
    def sync_deal!
      deal = @build.deal
      return unless @build.live?
      return if deal.cost_snapshotted?

      lines = @build.lines.reload.select(&:priced?)
      extras = lines.reject { |l| %w[base option freight].include?(l.kind) }
      t = @build.totals.to_h
      ActiveRecord::Base.transaction do
        tagged = deal.deal_products.reload.select { |dp| dp.notes.to_s.match?(TAG) }
        home = tagged.find { |dp| tag_of(dp) == 'home' } || deal.home_line_item
        kept = [write_home_line(deal, home, lines, extras, t)]
        extras.each do |l|
          dp = tagged.find { |d| tag_of(d) == l.id.to_s }
          kept << write_extra_line(deal, dp, l)
        end
        tagged.reject { |dp| kept.include?(dp) }.each(&:destroy!)
        allocate_tax(deal, t)
        d = t['discounts'] || {}
        tax = t['tax'] || {}
        rates = tax['rates'] || {}
        collected = tax['payer'] == 'dealer_collects'
        deal.update_columns(dealer_discount: d['savings'] || 0, sales_event_discount: d['sale'] || 0,
                            preferred_payment_discount: d['preferred'] || 0, manager_discount: d['other'] || 0,
                            tax_amount: tax['collected'] || 0, total_tax_amount: tax['collected'] || 0,
                            state_tax_rate: collected ? rates['state'] : nil, county_tax_rate: collected ? rates['county'] : nil,
                            city_tax_rate: collected ? rates['city'] : nil, total_amount: t['contract_total'] || 0,
                            unpaid_balance: t['unpaid_balance'] || 0, updated_at: Time.current)
      end
    end

    # The tax the sheet collects, spread over the deal's taxable lines in
    # proportion to their price, so Products shows them taxed and the deal's
    # value is the selling price plus tax. Rounding lands on the home line.
    def allocate_tax(deal, totals)
      collected = totals.dig('tax', 'collected').to_d
      lines = deal.deal_products.reload.to_a
      taxable = lines.reject { |dp| dp.notes.to_s.include?('taxable:no') }
      taxable = taxable.select { |dp| dp.notes.to_s.match?(TAG) || dp.tax.to_d.positive? }
      base = taxable.sum { |dp| net(dp) }
      shares = taxable.to_h { |dp| [dp, base.positive? ? (collected * net(dp) / base).round(2) : 0.to_d] }
      home = taxable.find { |dp| tag_of(dp) == 'home' } || taxable.first
      shares[home] += collected - shares.values.sum if home
      (lines - taxable).each { |dp| dp.update!(tax: 0) if dp.tax.to_d.positive? && dp.notes.to_s.match?(TAG) }
      shares.each { |dp, amount| dp.update!(tax: amount) if dp.tax.to_d != amount }
      deal.update_columns(value: deal.deal_products.reload.sum(:total))
    end

    # Clearing the build: its add-on lines go; the home line stays as a plain line.
    def release_deal!
      @build.deal.deal_products.select { |dp| dp.notes.to_s.match?(TAG) }.each do |dp|
        if tag_of(dp) == 'home'
          dp.update!(notes: dp.notes.to_s.gsub(/,?\s*deal_sheet:home/, ''))
        else
          dp.destroy!
        end
      end
    end

    private

    def guard!
      raise Locked, 'This build is locked by a signed agreement; change it with a change order' if @build.locked?
    end

    def engine(option_ids:, addon_ids:)
      lot = @build.source == 'lot'
      result = PricingEngine.new(company: @build.company, variant: @build.variant, option_ids: option_ids, addon_ids: addon_ids,
                                 location: @build.location, construction: @build.construction, quote: true,
                                 freight_miles: (freight_miles unless lot), assume_freight: !lot).call
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
      if %w[custom template].include?(line.kind)
        meta.delete('not_offered')
      elsif source
        meta.delete('not_offered')
        meta['rule'] = source.dig(:detail, :rule)
        # The base's make-up for the home tiles: factory base, surcharges, program discount.
        if line.kind == 'base'
          d = source[:detail] || {}
          meta['base'] = { 'net_base_price' => d[:net_base_price], 'required_adders' => d[:required_adders],
                           'program_discount' => d[:program_discount] }.deep_stringify_keys
        end
        line.unit_cost = source[:cost] unless meta['set_cost']
        line.unit_retail = source[:retail] unless meta['set_retail']
        line.is_standard = source.dig(:detail, :standard) == true if line.kind == 'option'
        line.label = self.class.option_label(line.option) if line.kind == 'option' && line.option
        meta['freight'] = source[:detail].deep_stringify_keys if line.kind == 'freight' && source[:detail]
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
      discounts = discounts_for(lines, retail)
      # Lines someone added in Products (not written by the sheet) are part of
      # the sale too: their price, cost and tax count here.
      others = other_deal_lines
      other_net = others.sum { |dp| net(dp) }
      cost += others.sum { |dp| dp.line_cost_total.to_d }
      selling = retail && (retail - discounts.values.sum + other_net)
      tax = tax_for(counted, selling, others)
      # A use-tax state (Ohio) has the dealer owe tax on its own cost: a cost of the sale.
      cost += tax[:use_tax].to_d
      deal = @build.deal
      contract_total = selling && ([selling - deal.trade_allowance.to_d, 0].max + tax[:collected].to_d)
      unpaid = contract_total && (contract_total - deal.down_payment.to_d - deal.try(:additional_payment).to_d)
      @warnings << tax[:note] if tax[:note]
      margin = selling && (selling - cost)
      margin_pct = selling&.positive? ? (margin / selling * 100).round(1) : nil
      if margin_pct && terms.margin_floor_pct && margin_pct < terms.margin_floor_pct.to_d
        @warnings << "Margin #{margin_pct}% is under your #{terms.margin_floor_pct.to_d.to_s('F')}% floor."
      end
      unpriced = counted.select { |l| l.retail.nil? }.map(&:label)
      @warnings << "No retail price yet for #{unpriced.to_sentence}." if unpriced.any?
      { version: TOTALS_VERSION, cost: cost.round(2).to_f, gross: retail&.round(2)&.to_f, retail: selling&.round(2)&.to_f,
        discounts: discounts.transform_values { |v| v.round(2).to_f }, discount_total: discounts.values.sum.round(2).to_f,
        other_lines_total: other_net.round(2).to_f,
        margin: margin&.round(2)&.to_f, margin_pct: margin_pct&.to_f,
        trade_allowance: deal.trade_allowance.to_f, trade_payoff: deal.trade_payoff.to_f, tax: tax.except(:rules, :note),
        contract_total: contract_total&.round(2)&.to_f, down_payment: deal.down_payment.to_f,
        additional_payment: deal.try(:additional_payment).to_f, unpaid_balance: unpaid&.round(2)&.to_f,
        delivery_point: deal.try(:delivery_point), freight_miles: (@build.freight_miles unless @build.source == 'lot'),
        freight_miles_note: @freight_note, tbd_count: lines.count(&:tbd), rounded_to: terms.round_retail_to, warnings: @warnings.uniq }
    end

    # Sales tax by the taxing state's rules (Tax::DealTax): the same numbers GL
    # posting uses. A line the rep marked not taxable in Products is left out
    # of the taxed amount.
    def tax_for(counted, selling, others)
      deal = @build.deal
      return Tax::DealTax.new(deal: deal, selling_price: 0, home_sale: true).call.merge(note: nil) unless selling

      extras = counted.reject { |l| %w[base option freight].include?(l.kind) }
      untaxed = extras.select { |l| untaxed_tags.include?(l.id.to_s) }.sum { |l| l.retail.to_d }
      # The home line: the selling price less the extras and the other lines.
      untaxed += selling - others.sum { |dp| net(dp) } - extras.sum { |l| l.retail.to_d } if untaxed_tags.include?('home')
      untaxed += others.reject { |dp| dp.tax.to_d.positive? }.sum { |dp| net(dp) }
      core = counted.select { |l| %w[base option].include?(l.kind) }
      freight = counted.select { |l| l.kind == 'freight' }
      Tax::DealTax.new(deal: deal, selling_price: [selling - untaxed, 0].max, trade: deal.trade_allowance,
                       cost_basis: core.sum { |l| l.cost.to_d }, freight_cost: freight.sum { |l| l.cost.to_d },
                       used: @build.vehicle&.condition.to_s.casecmp?('used'), home_sale: true).call
    end

    # A deal line's price before tax: unit price x qty less its discount.
    def net(dp)
      subtotal = dp.quantity.to_i * dp.unit_price.to_d
      off = dp.discount_type == 'percentage' ? subtotal * dp.discount.to_d / 100 : dp.discount.to_d
      (subtotal - off).round(2)
    end

    # Deal lines the sheet did not write.
    def other_deal_lines
      @build.deal.deal_products.reload.reject { |dp| dp.notes.to_s.match?(TAG) || dp.home_line_item? }
    end

    # Sheet lines the rep marked not taxable in Products ('taxable:no').
    def untaxed_tags
      @untaxed_tags ||= @build.deal.deal_products.select { |dp| dp.notes.to_s.include?('taxable:no') }.filter_map { |dp| tag_of(dp) }
    end

    # The buyer discounts in dollars, from the build's percents.
    def discounts_for(lines, gross)
      d = @build.discounts.to_h
      msrp = lines.find { |l| l.kind == 'base' }&.retail.to_d
      savings = (msrp * d['savings_pct'].to_d / 100).round(2)
      sale = (msrp * d['sale_pct'].to_d / 100).round(2)
      preferred = gross ? ((gross - savings - sale) * d['preferred_pct'].to_d / 100).round(2) : 0.to_d
      { 'savings' => savings, 'sale' => sale, 'preferred' => preferred, 'other' => d['other_amount'].to_d.round(2) }
    end

    # The rep's miles, else the estimate from the plant to the homesite (kept
    # on the build), else the dealer's default in the engine.
    def freight_miles
      if @build.freight_miles_set
        @freight_note = 'Entered on this deal'
        return @build.freight_miles
      end
      est = Freight.estimate_miles(@build.variant, @build.deal)
      if est
        @build.update_column(:freight_miles, est.first) if @build.freight_miles != est.first
        @freight_note = est.last
        est.first
      else
        @build.update_column(:freight_miles, nil) if @build.freight_miles
        @freight_note = 'No homesite address yet: using your default miles'
        nil
      end
    end

    def tag_of(dp) = dp.notes.to_s[TAG, 1]

    # What sync_deal! writes as an extra line's name.
    def written_name(line)
      line.quantity == 1 ? line.label : "#{line.label} (#{line.quantity.to_d.to_s('F').sub(/\.0\z/, '')} #{line.unit})"
    end

    # A sheet line's deal product as Products saved it: anything that is not
    # what the sheet wrote was changed there, and the sheet takes it.
    def take_edits(line, dp)
      qty = [dp.quantity.to_i, 1].max
      price = net(dp)
      changes = {}
      meta = line.metadata.to_h
      changes[:label] = dp.product_name.to_s.strip if dp.product_name.present? && dp.product_name != written_name(line)
      if qty != 1
        # Products shows the sheet's line as one at its total; a quantity typed there multiplies it.
        changes[:quantity] = line.quantity.to_d * qty
      end
      new_qty = changes[:quantity] || line.quantity.to_d
      if price != line.retail.to_d || qty != 1
        changes[:unit_retail] = new_qty.positive? ? (price / new_qty).round(2) : price
        changes[:no_charge] = false if price.positive?
        meta['set_retail'] = true unless %w[custom template].include?(line.kind)
      end
      cost = (dp.cost.to_d * qty).round(2)
      if cost != line.cost.to_d
        changes[:unit_cost] = new_qty.positive? ? (cost / new_qty).round(2) : cost
        meta['set_cost'] = true unless %w[custom template].include?(line.kind)
      end
      line.update!(changes.merge(metadata: meta)) if changes.any?
    end

    # A line someone added in Products becomes a sheet line, and its deal
    # product is tagged as that line's so it is never counted twice.
    def adopt(dp)
      qty = [dp.quantity.to_i, 1].max
      category = dp.notes.to_s[/category:\s*(\w+)/i, 1].to_s.downcase
      line = add_line(kind: 'custom', label: dp.product_name.presence || 'Item', quantity: qty, unit: 'each',
                      unit_retail: (net(dp) / qty).round(2), unit_cost: dp.cost.to_d,
                      tax_category: category == 'fee' ? 'fee' : 'other', metadata: { 'from_products' => true })
      dp.update!(notes: tagged_notes(dp.notes, category.presence || 'other', line.id))
    end

    def write_home_line(deal, home, lines, extras, totals)
      core = lines.reject { |l| extras.include?(l) }
      # The home's price is the gross less the add-on lines, so the rounding
      # step stays on the home; the buyer discounts come off it.
      price = totals['gross'].to_d - extras.sum { |l| l.retail.to_d }
      cost = core.sum { |l| l.cost.to_d }
      # A home on the lot keeps what it really cost the dealer.
      base = core.find { |l| l.kind == 'base' }
      lot_cost = @build.source == 'lot' && !base&.metadata.to_h['set_cost'] && @build.vehicle&.structured_cost
      cost = lot_cost.to_d + core.select { |l| l.kind == 'option' }.sum { |l| l.cost.to_d } if lot_cost
      cost += totals.dig('tax', 'use_tax').to_d # dealer-owed use tax is a cost of the home
      variant = @build.variant
      attrs = { product_name: "#{variant.manufacturer&.name} #{variant.catalog_plan.name} #{variant.model_number}".squish,
                unit_price: price, cost: cost, quantity: 1, discount: totals['discount_total'].to_d, discount_type: 'fixed',
                source_type: 'home', notes: tagged_notes(home&.notes, 'home', 'home') }
      if home
        home.update!(attrs)
        home
      else
        sku = @build.vehicle ? "VEHICLE-#{@build.vehicle.id}" : "HOMEBUILD-#{@build.id}"
        deal.deal_products.create!(attrs.merge(product_sku: sku, tax: 0))
      end
    end

    def write_extra_line(deal, dp, line)
      category = case line.kind
                 when 'template' then line.source_template_type == 'FeeTemplate' ? 'fee' : 'accessory'
                 when 'addon' then line.truebuild_addon&.fee? ? 'fee' : 'accessory'
                 else %w[setup delivery utility_connection].include?(line.tax_category) ? 'service' : (line.tax_category == 'fee' ? 'fee' : 'other')
                 end
      name = line.quantity == 1 ? line.label : "#{line.label} (#{line.quantity.to_d.to_s('F').sub(/\.0\z/, '')} #{line.unit})"
      attrs = { product_name: name, unit_price: line.retail.to_d, cost: line.cost.to_d, quantity: 1, discount: 0,
                discount_type: 'fixed', source_type: line.kind == 'template' ? 'template' : 'home_build',
                notes: tagged_notes(dp&.notes, category, line.id) }
      if dp
        dp.update!(attrs)
        dp
      else
        deal.deal_products.create!(attrs.merge(product_sku: "HOMEBUILD-LINE-#{line.id}", tax: 0))
      end
    end

    # Keeps the rep's own words; replaces our tags.
    def tagged_notes(existing, category, tag)
      own = existing.to_s.gsub(TAG, '').gsub(/category:\s*\w+/i, '').split(',').map(&:strip).reject(&:empty?).uniq
      ["category:#{category}", "deal_sheet:#{tag}", *own].join(', ')
    end

    def template_tax_category(template)
      return 'other' unless template.is_a?(FeeTemplate)

      text = "#{template.fee_type} #{template.name}".downcase
      return 'delivery' if text.match?(/deliver|transport|freight|escort/)
      return 'setup' if text.match?(/set[\s-]?up|block|level|anchor|skirt|install/)
      return 'utility_connection' if text.match?(/utilit|hook[\s-]?up|connect|septic|well/)

      'fee'
    end

    # The options this one replaces: the others in its set, or in its group
    # when the group is single-choice.
    def alternatives(option)
      others = CatalogOption.where(manufacturer_id: option.manufacturer_id, catalog_option_group_id: option.catalog_option_group_id)
                            .where.not(id: option.id)
      return others if option.group&.selection_type == 'single'

      if (set = option.metadata.to_h['color_set'].presence)
        others.where("metadata->>'color_set' = ?", set)
      elsif (set = self.class.choice_set(option))
        others.where(kind: 'standard').where('name ILIKE ?', "#{ActiveRecord::Base.sanitize_sql_like(set)}:%")
      else
        CatalogOption.none
      end
    end

    def add_line(**attrs)
      @build.lines.create!(position: next_position, **attrs)
    end

    def add_option_line(option)
      add_line(kind: 'option', option: option, label: self.class.option_label(option), group_name: option.group&.name, factory_code: option.factory_code,
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
