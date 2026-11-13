# frozen_string_literal: true

module DealDesk
  # Comparable-unit matching + side-by-side compare for the Deal Desk.
  #
  # The desk treats the home as a swappable slot. Given the deal's anchor unit and the
  # rep's current working structure, this finds matching units and ranks them by how well
  # they hit the customer's payment, the dealer's gross, and inventory health (aged stock
  # is weighted UP so the classic "200-day unit at another lot" surfaces).
  #
  #   Hard filter:  bedrooms + bathrooms exact match.
  #   Soft window:  price band from the company setting (±$ or ±%).
  #   Candidate set: driven by the anchor's home status (on-hand vs. orderable),
  #                  widenable to include orderable configs and other locations.
  #
  # CROSS-LOCATION: by default candidates are restricted to the deal's location. With
  # include_other_locations, the query intentionally spans all of @company's locations —
  # a deliberate, controlled exception to for_current_location. This is VISIBILITY ONLY;
  # initiating a transfer is gated separately (deal_desk:transfer_unit, Phase 4).
  #
  # Dealer gross in the output is INTERNAL ONLY — the Phase 4 controller strips it for
  # users without cost-view permission and for every customer-facing surface.
  #
  # STRUCTURE: pass the open `scenario:` and every home is priced on that scenario's own
  # structure (DealDeskScenario#engine_inputs_for_unit): its term, rate, down, trade, rebates,
  # fees, F&I and deal add-on lines, with only the home, its price, its cost and its own
  # included packages swapped. The row for the scenario's current home is its engine_inputs
  # unchanged, so it equals the Recap. Without a scenario (legacy callers) the base_structure /
  # deal defaults below are used.
  class CompareService
    # The deal's home is not an inventory unit (a TrueBuild or factory order), so there is no
    # bedroom/bathroom anchor to match. The controller answers 422 with this message.
    class NoInventoryHome < StandardError
      def initialize(msg = 'Compare units needs a home from inventory on this deal. ' \
                           'This deal is for a custom or factory order home, so there are no units to match it against.')
        super
      end
    end

    DEFAULT_WEIGHTS = { fit: 0.5, gross: 0.3, aged: 0.2 }.freeze
    DEFAULT_TERM_MONTHS = 180
    # How far a payment may exceed the target before its fit hits zero (fraction of target).
    # Meeting the target = full fit; a unit that misses the customer's number should not beat
    # one that hits it on gross alone. Centers the ranking on "solve FOR the payment".
    MISS_TOLERANCE = 0.10

    def initialize(company:, deal:, base_structure: {}, target_payment: nil,
                   include_orderable: false, include_other_locations: false, weights: {}, scenario: nil)
      @company = company
      @deal = deal
      @scenario = scenario
      @anchor = deal.vehicle
      @base = scenario ? scenario.engine_inputs : default_base_structure.merge(symbolize(base_structure))
      @target = target_payment.nil? ? nil : target_payment.to_f
      @include_orderable = include_orderable
      @include_other_locations = include_other_locations
      @weights = DEFAULT_WEIGHTS.merge(symbolize(weights))
      @tiers = company.deal_desk_days_on_lot_tiers
      @anchor_location_id = deal.location_id || @anchor&.location_id
    end

    def call
      raise NoInventoryHome if @anchor.nil?

      rows = decorate_and_solve(candidate_units)
      {
        anchor: anchor_row,
        price_band: price_band,
        filters: {
          bedrooms: @anchor.bedrooms,
          bathrooms: @anchor.bathrooms.to_f,
          anchor_status: @anchor.status,
          include_orderable: @include_orderable,
          include_other_locations: @include_other_locations,
          target_payment: @target
        },
        candidates: rank(rows)
      }
    end

    private

    # --- Candidate query --------------------------------------------------------
    def candidate_units
      scope = @company.vehicles.active
                      .where(bedrooms: @anchor.bedrooms, bathrooms: @anchor.bathrooms)
                      .where(status: candidate_statuses)
                      .where.not(id: @anchor.id)

      # Location scoping. Default: deal's location only. Widened: all @company locations
      # (the deliberate cross-location exception — still @company-isolated).
      unless @include_other_locations
        scope = scope.where(location_id: @anchor_location_id) if @anchor_location_id
      end

      # Price-band filter is applied IN RUBY (not SQL) against the RESOLVED price
      # (Vehicle#total_home_price — honors msrp + packages + discount), because the raw
      # sale_price column is only populated for units with a special discount. Filtering
      # on the column alone silently dropped (or zero-financed) every list-priced unit.
      units = scope.to_a
      band = price_band
      if band[:min] && band[:max]
        units.select! do |v|
          p = resolved_price(v)
          p.positive? && p >= band[:min] && p <= band[:max]
        end
      else
        units.select! { |v| resolved_price(v).positive? }
      end

      units
    end

    def candidate_statuses
      on_hand = @anchor.status != 'available_to_order'
      statuses = [on_hand ? 'available' : 'available_to_order']
      if @include_orderable
        statuses << 'available_to_order'
        statuses << 'available'
      end
      statuses.uniq
    end

    # --- Solve + decorate -------------------------------------------------------
    def decorate_and_solve(units)
      return units.map { |v| decorate(v, scenario_solve(v)) } if @scenario

      inputs = units.map do |v|
        { vehicle_id: v.id, price: resolved_price(v), unit_cost: unit_cost_for(v), pack_amount: pack_amount }
      end
      solved = Solver.new(@base).batch_solve(inputs, target_payment: @target)

      units.each_with_index.map do |v, i|
        decorate(v, solved[i])
      end
    end

    # One candidate on the scenario's structure. The home line is priced without its packages
    # (UnitPrice.home_price) because the packages ride as that unit's own add-on lines, exactly
    # as the scenario carries them after "Use this unit". Same row shape as batch_solve.
    def scenario_solve(vehicle)
      inputs = @scenario.engine_inputs_for_unit(
        vehicle, price: UnitPrice.home_price(vehicle), unit_cost: unit_cost_for(vehicle)
      )
      r = Engine.compute(inputs)
      row = { monthly_payment: r.monthly_payment, amount_financed: r.amount_financed,
              out_the_door: r.out_the_door, gross: r.gross }
      row[:met] = r.monthly_payment <= @target + 0.01 unless @target.nil?
      row
    end

    # Candidate price = the resolved list price the rest of the app shows
    # (Vehicle#total_home_price: msrp + included packages, honoring special discount),
    # NOT the raw sale_price column (only set when a special discount is enabled). The
    # anchor uses the deal's negotiated price instead — see resolved_anchor_price.
    def resolved_price(vehicle)
      p = vehicle.respond_to?(:total_home_price) ? vehicle.total_home_price.to_f : 0.0
      return p if p.positive?

      # Fallbacks if total_home_price is unavailable/zero: msrp, then sale_price.
      [vehicle.msrp.to_f, vehicle.sale_price.to_f].find(&:positive?) || 0.0
    end

    # Dealer cost for gross. Uses Vehicle#structured_cost (total_cost, else dealer_cost +
    # freight + pdi), the SAME basis the deal/GP/COGS use. Returns nil when no cost is
    # known — so the engine reports gross as indeterminate (nil) rather than treating
    # missing cost as $0.
    def unit_cost_for(vehicle)
      cost = vehicle.respond_to?(:structured_cost) ? vehicle.structured_cost : nil
      cost ||= vehicle.cost || vehicle.dealer_cost || vehicle.total_cost
      cost&.to_f
    end

    def pack_amount
      @pack_amount ||= @company.respond_to?(:default_pack_amount) ? @company.default_pack_amount.to_f : 0.0
    end

    def decorate(vehicle, solved)
      days = days_on_lot(vehicle)
      tier = aged_tier(days)
      {
        vehicle_id: vehicle.id,
        stock_number: vehicle.stock_number,
        inventory_id: vehicle.inventory_id,
        name: [vehicle.year, vehicle.make, vehicle.model].compact.join(' '),
        bedrooms: vehicle.bedrooms,
        bathrooms: vehicle.bathrooms.to_f,
        sale_price: resolved_price(vehicle),
        status: vehicle.status,
        location_id: vehicle.location_id,
        location_name: location_name(vehicle.location_id),
        days_on_lot: days,
        aged_tier: tier,
        is_aged: !tier.nil?,
        is_cross_location: cross_location?(vehicle),
        monthly_payment: solved[:monthly_payment],
        amount_financed: solved[:amount_financed],
        out_the_door: solved[:out_the_door],
        dealer_gross: solved[:gross]&.total, # INTERNAL ONLY
        meets_target: solved[:met]
      }
    end

    def anchor_row
      r = Engine.compute(anchor_inputs)
      days = days_on_lot(@anchor)
      tier = aged_tier(days)
      {
        vehicle_id: @anchor.id, is_anchor: true,
        stock_number: @anchor.stock_number, inventory_id: @anchor.inventory_id,
        name: [@anchor.year, @anchor.make, @anchor.model].compact.join(' '),
        bedrooms: @anchor.bedrooms, bathrooms: @anchor.bathrooms.to_f,
        sale_price: resolved_anchor_price, status: @anchor.status,
        location_id: @anchor.location_id, location_name: location_name(@anchor.location_id),
        days_on_lot: days, aged_tier: tier, is_aged: !tier.nil?, is_cross_location: false,
        monthly_payment: r.monthly_payment, amount_financed: r.amount_financed,
        out_the_door: r.out_the_door, dealer_gross: r.gross&.total,
        meets_target: @target.nil? ? nil : r.monthly_payment <= @target + 0.01
      }
    end

    # The deal's own home. On the scenario path this is the scenario's engine_inputs when the
    # scenario is structured on that home (so it equals the Recap), otherwise the deal's
    # negotiated price and package lines on the scenario's structure.
    def anchor_inputs
      if @scenario
        @scenario.engine_inputs_for_unit(@anchor, price: resolved_anchor_price, unit_cost: resolved_anchor_cost)
      else
        @base.merge(price: resolved_anchor_price, unit_cost: resolved_anchor_cost, pack_amount: pack_amount)
      end
    end

    # Anchor PRICE = the deal's NEGOTIATED home price, not raw inventory. The anchor is
    # this customer's actual deal, so its payment must match the deal: use the home line
    # item price (== selling_price via the mirror), falling back to selling_price, then to
    # the resolved inventory price for legacy deals that carry neither.
    def resolved_anchor_price
      deal_price = @deal.home_line_item_price || @deal.selling_price
      dp = deal_price.to_f
      dp.positive? ? dp : resolved_price(@anchor)
    end

    # Anchor COST = the deal's unit cost basis (Deal#vehicle_landed_cost: live vehicle
    # structured cost while open, snapshot once closed, line-item mirror fallback) — the
    # SAME basis GP/COGS use. Unit-only (no reconditioning) so the anchor's gross compares
    # apples-to-apples with candidates, which can only offer unit cost. Falls back to the
    # vehicle's structured cost; nil when no cost exists anywhere (gross indeterminate).
    def resolved_anchor_cost
      ac = @deal.respond_to?(:vehicle_landed_cost) ? @deal.vehicle_landed_cost : nil
      ac ||= unit_cost_for(@anchor)
      ac&.to_f
    end

    # --- Ranking ----------------------------------------------------------------
    def rank(rows)
      grosses = rows.map { |r| r[:dealer_gross] }.compact
      gmin = grosses.min
      gmax = grosses.max
      payments = rows.map { |r| r[:monthly_payment] }.compact
      pmin = payments.min
      pmax = payments.max

      rows.each do |r|
        fit   = payment_fit(r[:monthly_payment], pmin, pmax)
        gross = normalize(r[:dealer_gross], gmin, gmax)
        aged  = aged_bonus(r[:aged_tier])
        r[:score] = (@weights[:fit] * fit + @weights[:gross] * gross + @weights[:aged] * aged).round(4)
        r[:score_breakdown] = { fit: fit.round(3), gross: gross.round(3), aged: aged.round(3) }
      end

      rows.sort_by { |r| [-r[:score], r[:monthly_payment].to_f] }
    end

    # Payment fit: with a target, meeting it scores full marks and over-target decays.
    # Without a target, lower payment scores higher across the candidate set.
    def payment_fit(payment, pmin, pmax)
      return 0.0 if payment.nil?

      if @target
        return 1.0 if payment <= @target

        over = (payment - @target) / @target
        [0.0, 1 - (over / MISS_TOLERANCE)].max
      else
        return 1.0 if pmax.nil? || pmax == pmin

        1 - ((payment - pmin) / (pmax - pmin))
      end
    end

    def normalize(value, min, max)
      return 0.0 if value.nil? || min.nil? || max.nil?
      return 1.0 if max == min

      (value - min) / (max - min)
    end

    # Aged-stock bonus: 0 for fresh, scaling up through the configured tiers
    # (e.g. [90,120,180] -> 1/3, 2/3, 1.0). Weights aged units up.
    def aged_bonus(tier)
      return 0.0 if tier.nil?

      idx = @tiers.sort.index(tier)
      return 0.0 if idx.nil?

      (idx + 1).to_f / @tiers.length
    end

    # Soft price window around the anchor's price, from the company setting (±$ or ±%).
    # Centers on the anchor's RESOLVED price (deal-negotiated price, falling back to
    # inventory) so the candidate window matches the price the desk is actually working.
    def price_band
      @price_band ||= begin
        anchor_price = resolved_anchor_price
        if anchor_price.nil? || anchor_price.zero?
          { center: nil, min: nil, max: nil }
        else
          pb = @company.deal_desk_price_band
          delta = pb[:mode] == 'percent' ? anchor_price * (pb[:pct] / 100.0) : pb[:amount]
          {
            center: anchor_price, mode: pb[:mode], delta: delta.round(2),
            min: (anchor_price - delta).round(2), max: (anchor_price + delta).round(2)
          }
        end
      end
    end

    # --- Inventory helpers ------------------------------------------------------
    def days_on_lot(vehicle)
      received = vehicle.date_in_stock || vehicle.created_at
      return nil if received.nil?

      (Date.current - received.to_date).to_i
    end

    # Highest days-on-lot tier the unit has crossed (nil = fresh / below first tier).
    def aged_tier(days)
      return nil if days.nil?

      @tiers.select { |t| days >= t }.max
    end

    def cross_location?(vehicle)
      return false if @anchor_location_id.nil?

      vehicle.location_id.present? && vehicle.location_id != @anchor_location_id
    end

    def location_name(id)
      return nil if id.nil?

      (@locations ||= @company.locations.index_by(&:id))[id]&.name
    end

    # --- Base structure (rep's working structure, defaulting from the deal) ------
    def default_base_structure
      {
        trade_allowance: @deal.trade_allowance.to_f,
        trade_payoff: @deal.trade_payoff.to_f,
        cash_down: @deal.down_payment.to_f,
        rebates: 0.0,
        fees: { doc: @deal.doc_fee.to_f, delivery: @deal.delivery_fee.to_f, setup: @deal.setup_fee.to_f },
        fni_products: [],
        tax_rate: deal_tax_rate,
        tax_mode: :full_price,
        apr: @company.default_finance_rate,
        term_months: DEFAULT_TERM_MONTHS
      }
    end

    # Deal stores state/county/city rates (decimal 8,5). Heuristic: values > 1 are stored
    # as percent (e.g. 8.25) -> convert to fraction; otherwise already a fraction.
    def deal_tax_rate
      total = [@deal.state_tax_rate, @deal.county_tax_rate, @deal.city_tax_rate].compact.sum(&:to_f)
      total > 1 ? total / 100.0 : total
    end

    def symbolize(hash)
      (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end
  end
end
