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
  #
  # The document fee is the dealer's, from Settings, TrueBuild pricing. A deal's
  # first sheet takes it when the sheet starts, and only a company admin can
  # change or remove it there. It never reaches back: a sheet that already exists, or a deal
  # that already has a doc fee, keeps the fee it has, and changing the setting
  # changes no sheet. The rep can bring a sheet up to the new figure themselves.
  class DealBuild
    class Locked < StandardError; end

    TAG = /deal_sheet:(\w+)/
    # The lines written to the deal as lines of their own (the rest roll into the home line).
    EXTRA_KINDS = %w[addon template custom].freeze
    # Bumped when totals gain or change a figure: an older sheet reprices when opened.
    TOTALS_VERSION = 9
    DOC_FEE_LABEL = 'Doc fee'
    DOC_FEE_LOCKED = 'This document fee comes from Settings, TrueBuild pricing, and cannot be changed on a Deal Sheet.'
    DOC_FEE_MISSING = 'No document fee is set. Enter it under Settings, TrueBuild pricing (0 if you do not charge one).'

    def self.doc_fee_name?(name) = Deal.doc_fee_name?(name)


    # Priced before the deal's lines last changed (a Products save), or by an
    # older version of these totals.
    def self.stale?(build)
      return false if build.locked? || Agreements::DealSheetLock.edit_problem(build)
      # A won deal's sheet holds what was sold; only a correction moves it.
      return false if build.deal.cost_snapshotted?
      return true if build.priced_at.nil? || build.totals.to_h['version'] != TOTALS_VERSION
      # A platform admin corrected one of its books since (Truebuild::PriceCorrector).
      books = [build.price_book, build.cost_book, build.options_book].compact.uniq
      return true if books.any? { |b| (at = b.metadata.to_h['corrected_at']).present? && Time.zone.parse(at) > build.priced_at }
      # The dealer changed their price list, names or colors, or the admin decided on one of those.
      company = build.company
      return true if [company.dealer_markup_rules, company.dealer_catalog_terms, company.catalog_price_requests, company.catalog_option_requests, company.dealer_colors, company.dealer_surcharge_rules]
                     .any? { |scope| (at = scope.maximum(:updated_at)) && at > build.priced_at }

      return true if terms_moved?(build)
      # The home's status changed in inventory, or was set before status counted.
      return true if build.vehicle && build.source != DealHomeBuild.source_for(build.vehicle)

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
        deal: deal, variant: variant, vehicle: vehicle, source: DealHomeBuild.source_for(vehicle), truebuild_design: design,
        location_id: deal.location_id || vehicle&.location_id, created_by: user, discounts: discounts,
        version_number: next_version(deal), label: label.presence, live: first
      )
      service = new(build).seed(design)
      service.make_live! if live && !first
      service
    end

    # Locked by a signed agreement, or out with the buyers for signature.
    def self.assert_editable!(build)
      problem = Agreements::DealSheetLock.edit_problem(build)
      raise Locked, problem if problem
    end

    # The deal form or Sale Details changed the trade, a payment or the homesite
    # since this was priced: the contract and the tax would be out of date.
    def self.terms_moved?(build)
      t = build.totals.to_h
      deal = build.deal
      t['trade_allowance'].to_f != deal.trade_allowance.to_f || t['down_payment'].to_f != deal.down_payment.to_f ||
        t['additional_payment'].to_f != deal.try(:additional_payment).to_f || t['site'] != site_of(deal)
    end

    def self.site_of(deal)
      [deal.try(:delivery_point), deal.delivery_street, deal.delivery_city, deal.delivery_state, deal.delivery_zip].map(&:to_s).join('|')
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

    # A change order the buyers signed (Agreements::BuyerChangeOrder): this
    # version replaces the signed LIVE one and is locked in its turn. Not
    # repriced: the buyers signed these prices. The deal is written from it,
    # won or posted too (see write_closed_deal!).
    def apply_signed_change!(from:, agreement: nil)
      DealHomeBuild.transaction do
        from.update!(live: false)
        @build.update!(live: true, status: 'locked')
        @build.deal.cost_snapshotted? ? write_closed_deal!(agreement) : sync_deal!
      end
      self
    end

    # Makes this version the one the deal is written from. The version it
    # replaces stays as a draft. Refused while the LIVE version is signed.
    def make_live!
      return reprice! if @build.live?

      current = @build.deal.home_build
      self.class.assert_editable!(current) if current
      self.class.assert_editable!(@build)

      DealHomeBuild.transaction do
        current&.update!(live: false)
        @build.update!(live: true)
      end
      reprice!
    end

    # correcting_by: the person correcting the unsigned LIVE sheet of a won deal.
    # Without it a won deal's sheet does not write the deal.
    def initialize(build, correcting_by: nil)
      @build = build
      @correcting_by = correcting_by
      @warnings = []
    end

    # The base home, freight and the dealer's always-included add-ons, plus
    # whatever the buyer chose when the build starts from their design.
    def seed(design = nil)
      result = engine(option_ids: design&.option_ids || [], addon_ids: design&.metadata.to_h['addon_ids'] || [])
      result&.lines.to_a.each do |l|
        case l[:kind]
        when 'base' then add_line(kind: 'base', label: l[:label], tax_category: 'home')
        # A home on the lot still has to get to the homesite, so it gets freight too.
        when 'freight' then add_line(kind: 'freight', label: l[:label], tax_category: 'delivery')
        when 'option' then add_option_line(CatalogOption.find(l[:option_id]))
        # Quote-only add-ons are the rep's to add, not every build's.
        when 'addon'
          addon = @build.company.truebuild_addons.find(l[:addon_id])
          next if l.dig(:detail, :mode) == 'quote_only' || upgrade_names.include?(addon.name.to_s.downcase)

          @build.lines.find_by(kind: 'addon', truebuild_addon_id: addon.id) || add_addon_line(addon)
        end
      end
      add_line(kind: 'base', label: base_label, tax_category: 'home') unless @build.lines.exists?(kind: 'base')
      seed_doc_fee
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
      # Picked again: it is decided, whatever it was left as.
      line.update!(tbd: false) if line.tbd
      reprice!
      line
    end

    # A different home. Its options are not this one's, so they go, with the
    # base and freight. What the rep added themselves stays: add-ons, typed
    # lines, fees, and their own upgrades when the maker is the same. A new maker
    # brings its own discount percents.
    def change_home!(variant, vehicle: nil)
      guard!
      same_maker = variant.manufacturer_id == @build.variant.manufacturer_id
      DealHomeBuildLine.transaction do
        @build.lines.reload.select { |l| %w[base freight].include?(l.kind) || (l.kind == 'option' && !(same_maker && l.option&.dealer_upgrade?)) }
              .each(&:destroy!)
        attrs = { variant: variant, vehicle: vehicle, source: DealHomeBuild.source_for(vehicle) }
        unless same_maker
          terms = DealerCatalogTerm.effective(@build.company, variant.manufacturer_id)
          attrs[:discounts] = @build.discounts.to_h.merge(DISCOUNTS.transform_values { |field| terms[field]&.to_f || 0.0 })
        end
        @build.update!(attrs)
        @dealer_options = @upgrade_names = nil
        seed
      end
      self
    end

    # Where the buyer takes the home: picking it up means no freight, and
    # delivery brings the line back for the rep to price.
    def follow_delivery_point(point)
      guard!
      freight = @build.lines.reload.select { |l| l.kind == 'freight' }
      if point == 'lot' then freight.each(&:destroy!)
      elsif freight.empty? then add_line(kind: 'freight', label: 'Freight', tax_category: 'delivery')
      end
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

    # Freight to the homesite on a sheet that has none (one started on a lot
    # home before lot homes got freight, or a rep who removed it).
    def add_freight
      guard!
      line = @build.lines.find_by(kind: 'freight') ||
             add_line(kind: 'freight', label: 'Freight', tax_category: 'delivery')
      reprice!
      line
    end

    # Miles from the plant (or the lot) to the homesite; nil goes back to the estimate.
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

    def add_custom(label:, unit_retail:, unit_cost: 0, quantity: 1, unit: 'each', tax_category: 'other', group_name: nil,
                   on_addendum: false, factory_order: nil, factory_code: nil, user: nil)
      guard!
      line = add_line(kind: 'custom', label: label, group_name: group_name, quantity: quantity, unit: unit, tax_category: tax_category,
                      unit_cost: unit_cost, unit_retail: unit_retail)
      put_on_addendum(line, user: user, factory_order: factory_order, factory_code: factory_code) if on_addendum
      reprice!
      line
    end

    # The rep's tick on a line they typed or an add-on or package from their
    # list. On: it counts on Addendum A as an option, and goes on the dealer's upgrades, so every sheet for this
    # factory offers it from then on. Off: back to a plain line, and off that
    # list (sheets that already have it keep it).
    def set_addendum(line, on, user: nil, factory_order: nil)
      guard!
      on ? put_on_addendum(line, user: user, factory_order: factory_order) : take_off_addendum(line, user: user)
      reprice!
      line
    end

    # Whether the dealer's own upgrade on this line goes on the factory PO: on
    # the upgrade, so every sheet follows it.
    def set_factory_order(line, on)
      guard!
      raise ArgumentError, 'Only an upgrade you added can change this' unless line.option&.dealer_upgrade?

      line.option.update!(metadata: line.option.metadata.to_h.merge('factory_order' => on))
      reprice!
    end

    # The rep bringing a sheet up to the dealer's current document fee, which
    # replaces any doc fee on it. Nothing else changes a fee already on a sheet.
    def use_dealer_doc_fee
      guard!
      fee = DealerCatalogTerm.effective(@build.company, @build.variant.manufacturer_id).doc_fee
      raise ArgumentError, DOC_FEE_MISSING if fee.nil?

      @build.lines.reload.select { |l| l.required_fee? || doc_fee_line?(l) }.each(&:destroy!)
      remove_products_doc_fees(@build.deal) if @build.live?
      add_required_doc_fee(fee) if fee.positive?
      reprice!
    end

    # The cost of a signed sheet moved (the hauler's bill came in): it is recorded
    # with no new signature, because the buyers' price does not change. Anything
    # that would change what they signed is refused.
    def correct_signed_cost(line, unit_cost, user:)
      raise ArgumentError, 'This version is not signed' unless @build.locked?
      raise ArgumentError, 'Only the LIVE version can be corrected this way' unless @build.live?

      @correcting_by = user
      signed_total = @build.totals.to_h['contract_total']
      DealHomeBuild.transaction do
        meta = line.metadata.to_h
        meta['set_cost'] = true unless %w[custom template].include?(line.kind)
        line.update!(unit_cost: unit_cost, cost: (unit_cost.to_d * line.quantity.to_d).round(2), metadata: meta)
        totals = totals_for(@build.lines.reload.to_a).deep_stringify_keys
        if totals['contract_total'] != signed_total
          raise ArgumentError, 'That cost changes the tax, so it changes what the buyers signed. Use a change order.'
        end

        @build.update!(totals: totals)
        @build.reload
        @build.deal.cost_snapshotted? ? write_closed_deal!(nil) : write_deal!(@build.deal)
      end
      self
    end

    # attrs: quantity, unit, tbd, no_charge, tax_category, notes; unit_retail
    # and unit_cost set this line's price and cost (kept through repricing
    # until cleared with nil); label and group_name only on custom and
    # template lines; surcharge, on the home, replaces the book's required
    # adders for this deal (nil goes back to the book's). The dealer's document
    # fee takes a company admin (user).
    def update_line(line, attrs, user: nil)
      guard!
      raise ArgumentError, DOC_FEE_LOCKED if line.required_fee? && !user&.effective_admin?

      attrs = attrs.to_h.symbolize_keys
      if attrs.key?(:tax_category) && !EXTRA_KINDS.include?(line.kind)
        raise ArgumentError, "#{line.label} has its own row on the contract"
      end
      changes = attrs.slice(:quantity, :unit, :tbd, :no_charge, :tax_category)
      # TBD (no price yet) and N/C (no charge) cannot both be true: setting one clears the other.
      changes[:no_charge] = false if ActiveModel::Type::Boolean.new.cast(changes[:tbd])
      changes[:tbd] = false if ActiveModel::Type::Boolean.new.cast(changes[:no_charge])
      changes.merge!(attrs.slice(:label, :group_name, :unit_cost)) if %w[custom template].include?(line.kind)
      changes.merge!(attrs.slice(:label)) if line.kind == 'addon'
      # A book line's cost is the book's; the rep can set what it really costs (the hauler's bill for
      # freight, a factory quote for an option), kept through repricing until cleared with nil.
      if !%w[custom template].include?(line.kind) && attrs.key?(:unit_cost)
        changes[:unit_cost] = attrs[:unit_cost]
        attrs[:unit_cost].nil? ? line.metadata.delete('set_cost') : line.metadata['set_cost'] = true
      end
      meta = line.metadata.to_h
      meta['notes'] = attrs[:notes] if attrs.key?(:notes)
      if line.required_fee? && attrs.key?(:unit_retail)
        meta['fee_override'] = { 'by' => user.full_name, 'by_id' => user.id, 'at' => Time.current.iso8601, 'was' => line.unit_retail.to_f }
      end
      if line.kind == 'base' && attrs.key?(:surcharge)
        attrs[:surcharge].blank? ? meta.delete('set_surcharge') : meta['set_surcharge'] = attrs[:surcharge].to_d.round(2).to_f
      end
      if attrs.key?(:unit_retail)
        changes[:unit_retail] = attrs[:unit_retail]
        %w[custom template].include?(line.kind) || attrs[:unit_retail].nil? ? meta.delete('set_retail') : meta['set_retail'] = true
      end
      line.update!(changes.merge(metadata: meta))
      reprice!
      line
    end

    def remove_line(line, user: nil)
      guard!
      raise ArgumentError, 'The home itself cannot be removed; change the model instead' if line.kind == 'base'
      raise ArgumentError, DOC_FEE_LOCKED if line.required_fee? && !user&.effective_admin?

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
        # The document fee is not the rep's to change here either: reprice writes it back.
        @build.lines.reload.select { |l| EXTRA_KINDS.include?(l.kind) && l.priced? && !l.required_fee? }.each do |line|
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
      follow_home_status
      apply_doc_fee!
      lines = @build.lines.reload.to_a
      result = engine(option_ids: lines.filter_map(&:catalog_option_id), addon_ids: lines.filter_map(&:truebuild_addon_id))
      priced = index(result)
      lines.each { |line| price_line(line, priced) }
      @build.update!(price_book: result&.book, cost_book: result&.cost_book, options_book: result&.options_book,
                     priced_at: Time.current, totals: totals_for(@build.lines.reload.to_a))
      sync_deal!
      self
    end

    # Writes the deal from the build (see the class comment). Once the deal is
    # won or posted to the GL its price and cost are frozen: only a change the
    # buyers sign, or a correction on the sheet, moves them (write_closed_deal!).
    def sync_deal!
      return unless @build.live?
      if @build.deal.cost_snapshotted?
        write_closed_deal!(nil) if @correcting_by
        return
      end

      write_deal!(@build.deal)
    end

    # A signed change order on a won or posted deal. The deal takes the new
    # lines and totals like any other, and also the selling price and cost
    # that froze at close (the cost moves by what the home's cost moved, so a
    # cost set at close for another reason is kept). A posted deal gets a
    # journal entry for the difference, dated today, and its invoice is
    # recalculated (paid draws stay as they are).
    def write_closed_deal!(agreement)
      deal = @build.deal
      before = Accounting::DealAccountingService.new(deal).posting_lines if deal.gl_posted?
      old_cost = deal.home_line_item&.cost.to_d
      write_deal!(deal)

      deal.reload
      new_cost = deal.home_line_item&.cost.to_d
      attrs = { selling_price: deal.home_line_item_price, unit_cost: new_cost }
      attrs[:home_cost] = deal.home_cost.to_d + new_cost - old_cost if deal.home_cost.to_d.positive?
      deal.update_columns(attrs)
      deal.reload

      if before
        Accounting::DealAccountingService.new(deal)
          .post_change_adjustment!(before: before, memo: agreement ? ['Change order', agreement.agreement_number].join(' ') : 'Deal Sheet correction',
                                   user: agreement&.prepared_by || @correcting_by)
      end
      invoice = deal.deal_invoice_id && deal.company.invoices.find_by(id: deal.deal_invoice_id)
      DealInvoiceService.new(deal).sync_invoice!(invoice) if invoice
      CommissionPaymentGeneratorService.new(deal).recalculate
    end

    def write_deal!(deal)
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
        # Commissions take the pack off from here. A pack someone set on the deal stays, and a closed deal keeps its figures.
        fill_deal_pack!(t['pack']) if t['pack'].to_d.positive?
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
    # The sheet fills a deal's blank pack and remembers it did, so clearing the
    # sheet takes it back off. A pack someone set on the deal stays either way.
    def fill_deal_pack!(amount)
      deal = @build.deal
      return if deal.pack_amount.present? || deal.cost_snapshotted?

      deal.update_columns(pack_amount: amount)
      @build.update_columns(metadata: @build.metadata.to_h.merge('pack_filled' => amount.to_f))
    end

    def release_deal!
      deal = @build.deal
      filled = @build.metadata.to_h['pack_filled']
      deal.update_columns(pack_amount: nil) if filled && deal.pack_amount.to_f == filled.to_f && !deal.cost_snapshotted?
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
      self.class.assert_editable!(@build)
    end

    # A new home priced on a deal that has a sheet carries that sheet's fee, or
    # none if it has none. A deal's first sheet takes the dealer's, unless the
    # deal already carries a doc fee or is already sold.
    def seed_doc_fee
      return if @build.lines.reload.any? { |l| l.required_fee? || doc_fee_line?(l) }

      deal = @build.deal
      live = deal.home_builds.where(live: true).where.not(id: @build.id).first
      if live
        fee = live.lines.find { |l| l.required_fee? || doc_fee_line?(l) }
        add_line(kind: 'custom', label: fee.label, group_name: fee.group_name, tax_category: 'fee', quantity: fee.quantity, unit: fee.unit,
                 unit_retail: fee.unit_retail, unit_cost: fee.unit_cost, metadata: fee.metadata.to_h.slice('required_fee')) if fee
        return
      end
      return if deal.cost_snapshotted?
      return if deal.deal_products.any? { |dp| dp.notes.to_s.match?(/category:\s*fee/i) && self.class.doc_fee_name?(dp.product_name) }

      fee = DealerCatalogTerm.effective(@build.company, @build.variant.manufacturer_id).doc_fee
      add_required_doc_fee(fee) if fee&.positive?
    end

    def add_required_doc_fee(fee)
      add_line(kind: 'custom', label: DOC_FEE_LABEL, group_name: 'Fees', tax_category: 'fee', unit_retail: fee, unit_cost: 0,
               metadata: { 'required_fee' => true })
    end

    # A sheet holding the dealer's fee holds only that one: a doc fee added in
    # Products comes back off rather than charging it twice. The amount stays
    # what it was when the sheet took it. A sheet without the dealer's fee is
    # left alone. With the setting cleared, the line becomes the rep's to edit.
    def apply_doc_fee!
      deal = @build.deal
      return if deal.cost_snapshotted? || deal.home_build&.locked?

      lines = @build.lines.reload.to_a
      required = lines.find(&:required_fee?)
      return unless required

      if DealerCatalogTerm.effective(@build.company, @build.variant.manufacturer_id).doc_fee.nil?
        return required.update!(metadata: required.metadata.to_h.except('required_fee'))
      end

      lines.select { |l| !l.required_fee? && doc_fee_line?(l) }.each(&:destroy!)
      remove_products_doc_fees(deal) if @build.live?
    end

    def doc_fee_line?(line)
      EXTRA_KINDS.include?(line.kind) && line.tax_category == 'fee' && self.class.doc_fee_name?(line.label)
    end

    # A doc fee entered in Products before the sheet took it in.
    def remove_products_doc_fees(deal)
      deal.deal_products.reload.each do |dp|
        next if dp.notes.to_s.match?(TAG) || dp.home_line_item?

        dp.destroy! if dp.notes.to_s.match?(/category:\s*fee/i) && self.class.doc_fee_name?(dp.product_name)
      end
    end

    # Any add-on, package or typed line can go on Addendum A, except the document
    # fee, which has its row on the contract. What it was is kept, so unticking
    # puts it back.
    def put_on_addendum(line, user:, factory_order:, factory_code: nil)
      return if line.kind == 'option' && line.option&.dealer_upgrade?
      raise ArgumentError, 'Only an add-on or a line typed on this sheet can go on Addendum A this way' unless EXTRA_KINDS.include?(line.kind)
      raise ArgumentError, 'The document fee has its own line on the contract' if line.required_fee? || doc_fee_line?(line)

      upgrade = DealerOptions.add_upgrade!(company: @build.company, manufacturer_id: @build.variant.manufacturer_id, name: line.label, factory_code: factory_code,
                                           cost: line.unit_cost, retail: line.unit_retail, factory_order: factory_order != false)
      # Already on their list at another figure: this deal keeps what the rep typed.
      saved = upgrade.metadata.to_h
      meta = line.metadata.to_h.except('from_products')
      meta['was_line'] = { 'kind' => line.kind, 'tax_category' => line.tax_category, 'group_name' => line.group_name, 'truebuild_addon_id' => line.truebuild_addon_id,
                           'source_template_type' => line.source_template_type, 'source_template_id' => line.source_template_id }
      meta['set_retail'] = true if saved['retail'].to_d != line.unit_retail.to_d
      meta['set_cost'] = true if saved['cost'].to_d != line.unit_cost.to_d
      line.update!(kind: 'option', option: upgrade, truebuild_addon_id: nil, source_template: nil, label: upgrade.name, group_name: upgrade.group&.name,
                   factory_code: upgrade.factory_code, tax_category: 'factory_option', metadata: meta)
    end

    def take_off_addendum(line, user:)
      return line.update!(tax_category: 'other') if line.kind == 'custom' && line.tax_category == 'factory_option'
      return if EXTRA_KINDS.include?(line.kind)
      raise ArgumentError, 'Only an upgrade you added can come off Addendum A this way' unless line.kind == 'option' && line.option&.dealer_upgrade?

      DealerOptions.remove_color!(line.option, user: user)
      was = line.metadata.to_h['was_line'].to_h
      addon = was['truebuild_addon_id'] && @build.company.truebuild_addons.find_by(id: was['truebuild_addon_id'])
      template = was['source_template_id'] && was['source_template_type'].to_s.safe_constantize&.where(company_id: @build.company_id)&.find_by(id: was['source_template_id'])
      # Back to what it was, or a plain line if that is gone from their list.
      kind = (was['kind'] == 'addon' && addon) || (was['kind'] == 'template' && template) ? was['kind'] : 'custom'
      line.update!(kind: kind, option: nil, truebuild_addon: kind == 'addon' ? addon : nil, source_template: kind == 'template' ? template : nil,
                   group_name: was['group_name'], factory_code: nil, tax_category: was['tax_category'].presence || 'other',
                   metadata: line.metadata.to_h.except('set_retail', 'set_cost', 'rule', 'dealer_cost_set', 'book_name', 'was_line'))
    end

    def engine(option_ids:, addon_ids:)
      return nil if manual_home?

      surcharge = @build.lines.find_by(kind: 'base')&.metadata.to_h['set_surcharge']
      result = PricingEngine.new(company: @build.company, variant: @build.variant, option_ids: option_ids, addon_ids: addon_ids,
                                 location: @build.location, construction: @build.construction, quote: true,
                                 freight_miles: freight_miles, assume_freight: true, surcharge: surcharge, pack: @build.vehicle&.pack_amount).call
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
      # A won deal's sheet keeps its prices through a correction; a home typed by hand has no book.
      frozen = @build.live? && @build.deal.cost_snapshotted? && !line.unit_retail.nil?
      if %w[custom template].include?(line.kind) || frozen || manual_home?
        meta.delete('not_offered')
      elsif source
        meta.delete('not_offered')
        meta['rule'] = source.dig(:detail, :rule)
        # The base's make-up for the home tiles: factory base, surcharges, program discount.
        if line.kind == 'base'
          d = source[:detail] || {}
          meta['base'] = { 'net_base_price' => d[:net_base_price], 'required_adders' => d[:required_adders],
                           'surcharge' => d[:surcharge], 'book_surcharge' => d[:book_surcharge], 'dealer_surcharge_set' => d[:dealer_surcharge_set],
                           'program_discount' => d[:program_discount], 'factory_net_base_price' => d[:factory_net_base_price] }.compact.deep_stringify_keys
        end
        line.unit_cost = source[:cost] unless meta['set_cost']
        line.unit_retail = source[:retail] unless meta['set_retail']
        # A home on the lot with an asking price sells at it (Tom 2026-11-11):
        # what inventory, the website and the rep say is what the sheet starts at.
        if line.kind == 'base'
          asking = meta['set_retail'] ? nil : lot_asking_price
          if asking
            line.unit_retail = asking
            meta['retail_from'] = 'asking_price'
          else
            meta.delete('retail_from')
          end
        end
        line.is_standard = source.dig(:detail, :standard) == true if line.kind == 'option'
        # The dealer's own cost from their price list, and their name for the option (E85).
        source.dig(:detail, :dealer_cost_set) ? meta['dealer_cost_set'] = true : meta.delete('dealer_cost_set')
        if line.kind == 'option' && line.option
          renamed = dealer_options.renamed?(line.option)
          renamed ? meta['book_name'] = line.option.name : meta.delete('book_name')
          line.label = dealer_options.label_for(line.option)
          # A code corrected in the price book reaches open sheets (and their factory PO).
          line.factory_code = line.option.factory_code if line.option.factory_code.present?
        end
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
      # A home on the lot costs what it really cost, as the deal records it.
      lot = lot_home_cost(counted)
      cost += lot.to_d - counted.find { |l| l.kind == 'base' }.cost.to_d if lot
      retail = counted.all? { |l| !l.retail.nil? } ? counted.sum { |l| l.retail.to_d } : nil
      terms = DealerCatalogTerm.effective(@build.company, @build.variant.manufacturer_id)
      retail = PricingEngine.round_retail(retail, terms) if retail
      discounts = discounts_for(lines, retail)
      warn_inventory_price(lines, discounts)
      # Lines someone added in Products (not written by the sheet) are part of
      # the sale too: their price, cost and tax count here.
      others = other_deal_lines
      warn_charged_twice(counted, others)
      other_net = others.sum { |dp| net(dp) }
      cost += others.sum { |dp| dp.line_cost_total.to_d }
      # The pack is overhead on this sheet's margin. It is never on a line, so the
      # factory PO, the home's cost and the books stay at what the factory bills.
      pack = pack_for(terms)
      cost += pack
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
      @warnings << DOC_FEE_MISSING if terms.doc_fee.nil?
      # Both can be right: freight from the plant, then delivery to the buyer's
      # site. Both can also be the same trip, so the rep gets asked, not overruled.
      delivery = lines.find { |l| l.kind.in?(%w[addon template custom]) && l.label.to_s.match?(/deliver/i) }
      if delivery && lines.any? { |l| l.kind == 'freight' }
        @warnings << "This sheet has Freight and #{delivery.label}. Keep both if they are separate trips. Take one off if they are the same trip."
      end
      { version: TOTALS_VERSION, cost: cost.round(2).to_f, pack: pack.round(2).to_f, gross: retail&.round(2)&.to_f, retail: selling&.round(2)&.to_f,
        discounts: discounts.transform_values { |v| v.round(2).to_f }, discount_total: discounts.values.sum.round(2).to_f,
        other_lines_total: other_net.round(2).to_f,
        margin: margin&.round(2)&.to_f, margin_pct: margin_pct&.to_f,
        trade_allowance: deal.trade_allowance.to_f, trade_payoff: deal.trade_payoff.to_f, tax: tax.except(:rules, :note),
        contract_total: contract_total&.round(2)&.to_f, down_payment: deal.down_payment.to_f,
        additional_payment: deal.try(:additional_payment).to_f, unpaid_balance: unpaid&.round(2)&.to_f,
        home_cost: lot&.to_f, site: self.class.site_of(deal), delivery_point: deal.try(:delivery_point), freight_miles: @build.freight_miles,
        freight_miles_note: @freight_note, tbd_count: lines.count(&:tbd), rounded_to: terms.round_retail_to&.to_f, warnings: @warnings.uniq }
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

    # A line added in Products that the sheet also carries is charged twice
    # (Factory Direct deal 449, 2026-11-05: Package C and Summit Kitchen were in
    # Products before the sheet, then picked on it). The names rarely match, so
    # one name inside the other, or the same price and cost, counts as the same.
    def warn_charged_twice(counted, others)
      squash = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
      sheet = counted.reject { |l| %w[base freight].include?(l.kind) }
      others.each do |dp|
        name = squash.call(dp.product_name)
        price = net(dp)
        twin = sheet.find do |l|
          label = squash.call(l.label)
          by_name = name.length >= 6 && label.length >= 6 && (label.include?(name) || name.include?(label))
          by_price = price.positive? && l.retail.to_d == price && l.cost.to_d == dp.line_cost_total.to_d
          by_name || by_price
        end
        next unless twin

        @warnings << "#{dp.product_name} is on this sheet as #{twin.label.to_s.truncate(60)} and also on the deal from Products, " \
                     'so it is charged twice. Remove one of them.'
      end
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

    # The rep's miles, else the estimate from the plant (or, for a home on the
    # lot, from the lot) to the homesite (kept on the build), else the
    # dealer's default in the engine.
    def freight_miles
      if @build.freight_miles_set
        @freight_note = 'Entered on this deal'
        return @build.freight_miles
      end
      return lot_freight_miles if @build.source == 'lot'

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

    # A lot home travels from the lot, not the plant, so the dealer's default
    # (plant) miles would overstate it. With no homesite yet it is 0 miles
    # until the rep enters them or adds the delivery address.
    def lot_freight_miles
      est = Freight.estimate_lot_miles(@build.vehicle, @build.deal)
      miles, @freight_note = est || [0, 'No homesite address yet: enter the miles from your lot']
      @build.update_column(:freight_miles, miles) if @build.freight_miles != miles
      miles
    end

    def tag_of(dp) = dp.notes.to_s[TAG, 1]

    # On the lot or still to order, as the home's status says. A won deal stays as sold.
    def follow_home_status
      return if @build.vehicle.nil? || @build.deal.cost_snapshotted?

      source = DealHomeBuild.source_for(@build.vehicle)
      @build.update!(source: source) if @build.source != source
    end

    def manual_home? = @build.variant.manual_home?

    # One pack per deal: what the deal says (commissions read it too), else the
    # pack on this home in inventory, else the dealer's terms for this builder or
    # their All other homes figure, else the location or company default.
    def pack_for(terms)
      deal = @build.deal
      (deal.pack_amount.presence || @build.vehicle&.pack_amount.presence || terms.dealer_pack.presence || deal.effective_pack_amount).to_d
    end

    # The asking price typed on a home on the lot, nil when none (the price
    # list and markup price it then). The asking price (once Base Sale Price) is the msrp column; an
    # older home may carry only sale_price.
    def lot_asking_price
      vehicle = @build.vehicle
      return nil if vehicle.nil? || @build.source != 'lot' || manual_home?

      own = vehicle.msrp.to_d.positive? ? vehicle.msrp : (vehicle.special_discount_enabled ? nil : vehicle.sale_price)
      own.to_d.positive? ? own.to_d : nil
    end

    # Inventory can advertise a sale the sheet does not carry, and a buyer may
    # have seen that figure, so the rep is told.
    def warn_inventory_price(lines, discounts)
      vehicle = @build.vehicle
      return if vehicle.nil? || manual_home? || @build.deal.cost_snapshotted?

      listed = (vehicle.special_discount_enabled && vehicle.discounted_price.presence) || vehicle.msrp.presence || vehicle.sale_price.presence
      retail = lines.find { |l| l.kind == 'base' }&.retail
      return unless listed.to_d.positive? && retail

      sheet = retail.to_d - discounts['savings'] - discounts['sale']
      # A dollar either way is rounding: a price sheet rounds its sale price, the sheet rounds retail first.
      return if (sheet - listed.to_d).abs <= 1

      words = ActiveSupport::NumberHelper
      @warnings << "Inventory lists this home at #{words.number_to_currency(listed, precision: 0)}, but this sheet prices it at " \
                   "#{words.number_to_currency(sheet, precision: 0)}. Change one if the buyer was quoted the other."
    end

    # What a lot home really cost, unless the rep set the base cost; nil otherwise.
    def lot_home_cost(lines)
      base = lines.find { |l| l.kind == 'base' }
      return nil unless base && @build.source == 'lot' && !base.metadata.to_h['set_cost']

      @build.vehicle&.structured_cost
    end

    def upgrade_names
      @upgrade_names ||= @build.company.dealer_colors.active.where(manufacturer_id: @build.variant.manufacturer_id, kind: 'upgrade')
                               .pluck(:name).map { |n| n.to_s.downcase }
    end

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
      # step stays on the home; the buyer discounts come off it. With a line
      # still unpriced there is no gross: the home carries what is priced so far.
      price = totals['gross'] ? totals['gross'].to_d - extras.sum { |l| l.retail.to_d } : core.sum { |l| l.retail.to_d }
      cost = core.sum { |l| l.cost.to_d }
      # A home on the lot keeps what it really cost the dealer.
      if (lot = lot_home_cost(core))
        cost += lot.to_d - core.find { |l| l.kind == 'base' }.cost.to_d
      end
      cost += totals.dig('tax', 'use_tax').to_d # dealer-owed use tax is a cost of the home
      attrs = { product_name: FactoryOrder.home_name(@build),
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
    # when the group is single-choice. A color is one of its set only: Carpet
    # and Linoleum share Flooring, and picking a carpet keeps the linoleum.
    def alternatives(option)
      if option.metadata.to_h['color_set'].blank? && option.group&.selection_type == 'single'
        return CatalogOption.where(manufacturer_id: option.manufacturer_id, catalog_option_group_id: option.catalog_option_group_id)
                            .where.not(id: option.id).where("metadata->>'color_set' IS NULL")
      end
      return CatalogOption.none unless (set = self.class.choice_set(option))

      # Both shapes of a set: color options (a dealer's own colors are these)
      # and standard choices named "Set: Choice", so picking either kind
      # replaces the other.
      CatalogOption.where(manufacturer_id: option.manufacturer_id).where.not(id: option.id)
                   .where("(kind = 'color' AND metadata->>'color_set' = :set) OR (kind = 'standard' AND name ILIKE :named)",
                          set: set, named: "#{ActiveRecord::Base.sanitize_sql_like(set)}:%")
    end

    # The dealer's names and colors for this home's factory (backlog E85).
    def dealer_options
      @dealer_options ||= DealerOptions.new(@build.company, @build.variant.manufacturer_id)
    end

    def add_line(**attrs)
      @build.lines.create!(position: next_position, **attrs)
    end

    def add_option_line(option)
      # No book prices a home typed by hand: the dealer's own figures do.
      own = manual_home? ? option.metadata.to_h.slice('cost', 'retail') : {}
      add_line(kind: 'option', option: option, label: dealer_options.label_for(option), group_name: option.group&.name, factory_code: option.factory_code,
               unit: DealHomeBuildLine.unit_for(option.name), tax_category: 'factory_option',
               unit_cost: own['cost'].presence&.to_d, unit_retail: own['retail'].presence&.to_d)
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
      return @build.variant.catalog_plan.name if manual_home?

      "#{@build.variant.catalog_plan.name} (#{@build.variant.model_number})"
    end

    def next_position
      @build.lines.maximum(:position).to_i + 1
    end
  end
end
