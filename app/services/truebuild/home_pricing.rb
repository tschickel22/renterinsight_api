# frozen_string_literal: true

module Truebuild
  # Everything the inventory Pricing tab shows about one home, worked out in
  # one place so the screen, the list and a new deal sheet say the same thing
  # (Tom 2026-11-11). Two ideas: the asking price, and the cost.
  #
  #   listed     the asking price typed on the home (sale price while a
  #              discount runs, plus add-ons in the total), else the marked-up
  #              price
  #   marked_up  cost x markup: the price list's figure for a home on a price
  #              list, else the home's own cost + pack x the All homes rule
  #   cost       factory price + surcharge + freight + PDI, then pack. An
  #              invoice's surcharge is already inside the invoice, so it is
  #              shown and never added again.
  #
  # Cost, gross and margin only when include_cost.
  class HomePricing
    def initialize(company, inventory_pricing: nil)
      @company = company
      @inventory = inventory_pricing || InventoryPricing.new(company)
    end

    def for(vehicle, include_cost:)
      book = vehicle.catalog_plan_variant_id ? @inventory.breakdown(vehicle, include_cost: true) : nil
      list = @inventory.list_price(vehicle)
      cost = cost_for(vehicle, book)
      marked = marked_up_for(vehicle, book, cost)
      listed = list && list[:amount]
      asking = vehicle.msrp.to_f.positive? ? vehicle.msrp.to_f : (vehicle.special_discount_enabled ? nil : vehicle.sale_price.to_f.nonzero?)

      out = {
        asking: asking,
        listed: listed,
        listed_from: list && (list[:source] == 'home' ? 'asking_price' : 'marked_up'),
        sale: vehicle.sale_live? ? vehicle.discounted_price.to_f : nil,
        on_price_list: book.present?,
        book_id: book&.dig(:book_id),
        # The price list row a "set it for every home of this model" choice saves to.
        price_list_row_id: book && CatalogVariantPrice.where(catalog_price_book_id: book[:book_id], catalog_plan_variant_id: vehicle.catalog_plan_variant_id).pick(:id),
        model_number: book&.dig(:model_number),
        price_list_name: book&.dig(:book_name),
        before_surcharge: book ? book[:before_surcharge] : false,
        markup: marked && marked.except(:cost_basis),
        has_invoice: vehicle.invoice.present?
      }
      return out unless include_cost

      your_cost = cost[:total] && (cost[:total] + cost[:pack]).round(2)
      gross = listed && your_cost ? (listed - your_cost).round(2) : nil
      out.merge(
        cost: cost.merge(your_cost: your_cost),
        markup: marked,
        gross: gross,
        margin_pct: gross && listed.positive? ? (gross / listed * 100).round(1) : nil
      )
    end

    private

    # The home's own cost lines first; a home on a price list with none fills
    # factory price and surcharge from it.
    def cost_for(vehicle, book)
      invoice = vehicle.invoice
      inv_surcharge = invoice&.material_surcharge.to_f
      surcharge, surcharge_from =
        if invoice && inv_surcharge.positive? then [inv_surcharge, 'invoice']
        elsif vehicle.surcharge_amount.to_f.positive? then [vehicle.surcharge_amount.to_f, 'home']
        elsif book && book[:surcharge].to_f.positive? then [book[:surcharge].to_f, 'price_list']
        end
      own_factory = vehicle.dealer_cost.to_f.positive? ? vehicle.dealer_cost.to_f : nil
      factory, factory_from =
        if own_factory then [own_factory, invoice ? 'invoice' : 'home']
        elsif book && book[:factory_base] then [book[:factory_base].to_f, 'price_list']
        end
      structured = vehicle.structured_cost&.to_f
      total, total_from =
        if vehicle.total_cost.to_f.positive? then [vehicle.total_cost.to_f, 'entered_total']
        elsif structured then [structured, 'lines']
        elsif book && book[:cost] then [book[:cost].to_f, 'price_list']
        end
      pack = vehicle.pack_amount.presence&.to_f || default_pack(vehicle)

      { factory_price: factory, factory_price_from: factory_from,
        surcharge: surcharge, surcharge_from: surcharge_from,
        # Counted in the total unless an invoice already carries it.
        surcharge_in_total: surcharge_from == 'invoice' ? 'included' : (surcharge ? 'added' : nil),
        freight: vehicle.freight_cost&.to_f, pdi: vehicle.pdi_cost&.to_f,
        total_entered: vehicle.total_cost.to_f.positive? ? vehicle.total_cost.to_f : nil,
        total: total, total_from: total_from, pack: pack.to_f,
        pack_from: vehicle.pack_amount.present? ? 'home' : 'terms' }
    end

    # Cost (with pack) x markup. A home on a price list uses the price list's
    # own figure, the one a deal sheet starts from without an asking price.
    def marked_up_for(vehicle, book, cost)
      if book
        basis = (book[:cost].to_f + book[:pack].to_f)
        times = basis.positive? ? (book[:retail].to_f / basis).round(4) : nil
        return { amount: book[:retail].to_f, rule: book[:markup], times: times, cost_basis: basis.round(2), from: 'price_list' }
      end

      defaults = StandAlonePricing.new(@company, location: vehicle.location).defaults
      rule = defaults[:markup]
      basis = cost[:total] && (cost[:total] + cost[:pack])
      amount = rule && rule[:times] && basis ? (basis * rule[:times]).round(2) : nil
      { amount: amount, rule: rule && 'All homes rule', times: rule&.dig(:times), sliding: rule&.dig(:type) == 'sliding' ? rule : nil,
        cost_basis: basis&.round(2), from: 'cost' }
    end

    def default_pack(vehicle)
      mfr = vehicle.catalog_plan_variant&.manufacturer_id
      DealerCatalogTerm.effective(@company, mfr).dealer_pack.to_f
    rescue StandardError
      0.0
    end
  end
end
