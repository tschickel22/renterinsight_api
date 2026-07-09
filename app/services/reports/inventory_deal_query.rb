# frozen_string_literal: true

module Reports
  # Shared inventory + deal query and canonical GP row builder, used by BOTH the
  # Inventory Stock List report and the Salesperson GP Pipeline report so neither
  # duplicates the scoping/query and both consume the SAME unified GP method.
  #
  # GP is read straight from Deal#front_gross / Deal#landed_cost — NEVER recomputed.
  # For available (no-deal) units the estimate is price − vehicle structured cost.
  # Missing cost is flagged, never guessed.
  class InventoryDealQuery
    OPEN_STAGES = %w[prospecting qualification needs_analysis proposal negotiation closing].freeze
    DEFAULT_PIPELINE = OPEN_STAGES

    AGING = {
      '0-30'  => (0..30),
      '31-60' => (31..60),
      '61-90' => (61..90),
      '90+'   => (91..Float::INFINITY)
    }.freeze

    def initialize(company, current_user: nil, scope: 'inventory', can_view_costs: false, filters: {})
      @company = company
      @current_user = current_user
      @scope = scope.to_s == 'accounting' ? 'accounting' : 'inventory'
      @can_view_costs = !!can_view_costs
      @filters = (filters || {}).symbolize_keys
    end

    attr_reader :can_view_costs, :scope, :filters

    # ---- Scoped data ---------------------------------------------------------

    def vehicles
      @vehicles ||= base_vehicle_scope
    end

    def vehicle_ids
      @vehicle_ids ||= vehicles.map(&:id)
    end

    def open_deals_by_vehicle
      @open_deals_by_vehicle ||= begin
        return {} if vehicle_ids.empty?

        @company.deals
                .where(vehicle_id: vehicle_ids, stage: open_stage_keys, deleted_at: nil)
                .includes(:primary_salesperson, :secondary_salesperson, :account, :contact, :owner)
                .group_by(&:vehicle_id)
      end
    end

    # Open = every configured pipeline stage that isn't a terminal
    # won (probability 100) or lost (probability 0) bucket. Reads from
    # the tenant's pipeline_stages setting via Company#pipeline_stage_keys
    # so custom stages ("construction", "factory_order", "delivery_pending",
    # etc.) that dealers add for MH/RV workflows still count as active
    # pipeline for report purposes. Falls back to the hardcoded default
    # list when a company hasn't customized its pipeline.
    def open_stage_keys
      @open_stage_keys ||= begin
        keys = @company.pipeline_stage_keys
        if keys.blank?
          OPEN_STAGES
        else
          keys.reject do |k|
            prob = @company.pipeline_stage_probability(k).to_i
            prob == 100 || prob == 0
          end
        end
      end
    end

    # ALL active deals per vehicle, any stage (incl. closed_won/closed_lost) — mirrors the
    # inventory detail "Related Deals" panel (vehicle.deals.active). Drives the report's
    # deal-preview popover so it shows every associated deal, not just open ones. The
    # contention count (open_deal_count) and resolved deal_id still come from open deals.
    def all_deals_by_vehicle
      @all_deals_by_vehicle ||= begin
        return {} if vehicle_ids.empty?

        @company.deals
                .where(vehicle_id: vehicle_ids, deleted_at: nil)
                .includes(:primary_salesperson, :secondary_salesperson, :account, :contact, :owner)
                .group_by(&:vehicle_id)
      end
    end

    # Deals on in-scope vehicles in the given stages (e.g. closed_won) — used for the
    # salesperson report's closed/funded pipeline buckets.
    def deals_for_vehicles(stages:)
      return [] if vehicle_ids.empty?

      @company.deals
              .where(vehicle_id: vehicle_ids, stage: stages, deleted_at: nil)
              .includes(:vehicle, :primary_salesperson, :secondary_salesperson, :account, :contact, :owner)
              .to_a
    end

    def vehicles_by_id
      @vehicles_by_id ||= vehicles.index_by(&:id)
    end

    # ---- Multi-deal resolution ----------------------------------------------

    def pipeline_stages
      @pipeline_stages ||= begin
        setting = Setting.get('Company', @company.id, 'pipeline_stages')
        list = case setting
               when Array then setting.map(&:to_s)
               when Hash  then setting.values.map(&:to_s)
               end
        list&.any? ? list : DEFAULT_PIPELINE
      end
    end

    def stage_rank(stage)
      pipeline_stages.index(stage.to_s) || -1
    end

    # "Closed" identified by probability=100 rather than stage name, so the Closed/Funded
    # section keeps working when a company renames the won stage (custom pipeline configs).
    def closed_won_stage_keys
      @closed_won_stage_keys ||= @company.pipeline_stage_keys.select do |key|
        @company.pipeline_stage_probability(key).to_i == 100
      end
    end

    # Most advanced open deal wins; tie-break on most recent.
    def resolve_open_deal(open_deals)
      return nil if open_deals.blank?

      open_deals.max_by { |d| [stage_rank(d.stage), d.created_at || Time.at(0)] }
    end

    # ---- Canonical row (consumes unified GP) --------------------------------

    # deal: the assigned deal (resolved open deal, or an explicit closed/funded deal).
    # open_deal_count: number of open deals on the vehicle (contention indicator).
    # deals: the deals to surface in the report's hover/click preview (all open deals on
    #   the unit, or the single funded deal). Already eager-loaded by the caller.
    def build_row(vehicle, deal: nil, open_deal_count: 0, deals: [])
      assigned = deal.present?
      status = vehicle.status
      flags = []

      on_order = status == 'available_to_order'
      flags << 'on_order' if on_order

      sold_no_deal = status == 'sold' && !assigned && vehicle.sold_via_deal_id.blank?
      flags << 'no_deal' if sold_no_deal

      cost = assigned ? deal.landed_cost : vehicle.structured_cost
      cost_missing = cost.nil?
      flags << 'cost_not_entered' if cost_missing && !sold_no_deal

      price = if sold_no_deal
                nil
              elsif assigned
                deal.selling_price
              else
                vehicle.total_home_price
              end

      calc_gp = if sold_no_deal || cost_missing || price.nil?
                  nil # GP "—"
                elsif assigned
                  deal.front_gross # CONSUME unified GP — never recompute
                else
                  (price.to_d - cost.to_d).round(2)
                end

      gp_pct = (calc_gp && price && price.to_d > 0) ? ((calc_gp.to_d / price.to_d) * 100).round(2) : nil

      age = on_order ? nil : (vehicle.date_in_stock ? (Date.current - vehicle.date_in_stock.to_date).to_i : nil)
      fp = floor_plan_index[vehicle.id]

      row = {
        vehicle_id: vehicle.id,
        deal_id: assigned ? deal.id : nil,
        # Customer linkage for report hyperlinks: prefer the contact, else the account.
        contact_id: assigned ? deal.contact_id : nil,
        account_id: assigned ? deal.account_id : nil,
        # "Stock #" matches the inventory detail page: the system-generated
        # Vehicle#inventory_id (e.g. "MH-20260523-3E5324"), NOT the dealer-entered
        # `stock_number` column (often blank or used for an internal alias).
        stock_number: vehicle.inventory_id.presence,
        # Vehicle#identifier returns VIN for RV, serial_number for MH (auto-copied from VIN
        # when blank) — so this is the right canonical "serial" field across listing types.
        serial_number: vehicle.identifier.presence,
        location: vehicle.location&.name || 'Unassigned location',
        age_days: age,
        offline: assigned ? deal.delivery_date : nil, # 'Not Ord' applied by callers without a deal
        customer: assigned ? deal.customer_display_name : nil,
        salesperson: assigned ? salesperson_name(deal.primary_salesperson) : nil,
        salesperson_id: assigned ? deal.primary_salesperson_id : nil,
        secondary_salesperson: assigned ? salesperson_name(deal.secondary_salesperson) : nil,
        secondary_salesperson_id: assigned ? deal.secondary_salesperson_id : nil,
        deposit: assigned ? deal.down_payment : nil,
        price: price,
        addon_gross: assigned ? deal.addon_gross : nil,
        lender: lender_for(deal, vehicle, fp),
        status: status_label(vehicle, deal, assigned),
        vehicle_status: status,
        open_deal_count: open_deal_count,
        # Turn = this model sold at this store ÷ this model sold company-wide (velocity;
        # not cost-derived, so ungated). nil when this model has no company-wide sales yet.
        turn: turn_for(vehicle.model, vehicle.location_id),
        manufacturer: vehicle.make,
        model: vehicle.model,
        year: vehicle.year,
        sections: vehicle.sections,
        bedrooms: vehicle.bedrooms,
        bathrooms: vehicle.bathrooms,
        # Box dimensions for the "Size" column (e.g., 16 × 76). The per-section
        # variants (width1/length1, …) aren't used here — Vehicle#length/width are
        # the canonical scalar dimensions surfaced everywhere else.
        length: vehicle.length,
        width: vehicle.width,
        condition: vehicle.condition,
        flags: flags,
        floorplan: fp && {
          principal: fp[:principal],
          lender: fp[:lender],
          days_on_plan: fp[:days_on_plan],
          accrued_interest: fp[:accrued_interest],
          monthly_interest_estimate: fp[:monthly_interest_estimate]
        },
        # Compact previews for the report's deal hover/click popover. Sorted so the
        # resolved (most advanced) deal — the one `deal_id` points at — is listed first.
        deals: deal_previews(deals)
      }

      # Cost/GP columns are omitted entirely when the user lacks view_cost_details.
      if @can_view_costs
        row[:cost] = cost
        row[:calc_gp] = calc_gp
        row[:gp_pct] = gp_pct

        # Max Advance (lender cap from the captured invoice) — gated with cost/GP since it
        # exposes cost basis. Uses the deal's lender when assigned, else the company default.
        # Exact from the invoice; '—' + flag when the invoice/lender is missing (never approximate).
        ma_lender = lender_record_for(deal)
        ma_price  = assigned ? deal.selling_price : price
        ma = MaxAdvanceSurfacing.evaluate(vehicle: vehicle, lender: ma_lender, deal: deal, price: ma_price)
        row[:max_adv_standard] = ma[:standard_msp]
        row[:max_adv_maximum]  = ma[:maximum_msp]
        row[:max_adv_status]   = ma[:status]
        row[:max_adv_lender]   = ma_lender&.name
        if ma[:standard_msp].nil? && (flag = MaxAdvanceSurfacing.flag_for(ma[:reason]))
          flags << flag
        end
      end

      row
    end

    # Compact deal records for the report preview popover (deal details + rep + value).
    # selling_price is price-tier data (already shown ungated), so this is not cost-gated.
    def deal_previews(deals)
      Array(deals)
        .sort_by { |d| [-stage_rank(d.stage), -(d.created_at || Time.at(0)).to_i] }
        .map do |d|
          {
            id: d.id,
            customer: d.customer_display_name,
            salesperson: salesperson_name(d.primary_salesperson),
            stage: d.stage,
            status: d.stage.to_s.titleize,
            value: d.selling_price
          }
        end
    end

    def salesperson_name(user)
      return nil unless user

      [user.try(:first_name), user.try(:last_name)].compact.join(' ').strip.presence || user.try(:email)
    end

    # ---- Floor plan ----------------------------------------------------------

    def floor_plan_report
      loc = @filters[:location_id].presence
      loc = nil if loc.to_s == 'all'
      @floor_plan_report ||= Accounting::FloorPlanService.new(@company).report(location_id: loc)
    end

    def floor_plan_index
      @floor_plan_index ||= floor_plan_report[:vehicles].index_by { |r| r[:vehicle_id] }
    end

    def floor_plan_summary
      floor_plan_report[:summary]
    end

    private

    # ---- Max Advance lender resolution ---------------------------------------

    def lenders_by_id
      @lenders_by_id ||= @company.lenders.index_by(&:id)
    end

    # Company-default lender for available (no-deal) units: first active lender by name.
    def default_lender
      return @default_lender if defined?(@default_lender)
      @default_lender = @company.lenders.active.by_name.first
    end

    def lender_record_for(deal)
      (deal && deal.lender_id && lenders_by_id[deal.lender_id]) || default_lender
    end

    # ---- Turn (sales velocity) ----------------------------------------------
    # Closed-won sales, keyed by the sold vehicle's model and location, so the row's
    # model+store turn aligns with what the row displays.

    def sold_deals
      @sold_deals ||= @company.deals
                              .where(stage: @company.won_stage_keys, deleted_at: nil)
                              .where.not(vehicle_id: nil)
                              .includes(:vehicle)
                              .to_a
    end

    def sold_company_counts
      @sold_company_counts ||= sold_deals.each_with_object(Hash.new(0)) do |dd, h|
        m = dd.vehicle&.model
        h[m] += 1 if m.present?
      end
    end

    def sold_store_counts
      @sold_store_counts ||= sold_deals.each_with_object(Hash.new(0)) do |dd, h|
        m = dd.vehicle&.model
        loc = dd.vehicle&.location_id
        h[[m, loc]] += 1 if m.present?
      end
    end

    def turn_for(model, location_id)
      return nil if model.blank?
      company_n = sold_company_counts[model].to_i
      return nil if company_n.zero?
      (sold_store_counts[[model, location_id]].to_f / company_n).round(4)
    end

    def base_vehicle_scope
      scope = @company.vehicles.where(is_deleted: [false, nil])

      # scope param: inventory honours the current location selector; accounting spans
      # all company locations. An explicit location_id filter (incl. 'all') overrides
      # the picker so the report's Location filter can actually escape it.
      scope = scope.for_current_location if @scope == 'inventory' && @filters[:location_id].blank?

      # ALWAYS enforce RBAC location filtering: company-tier admins see all; location-tier
      # users are restricted to their accessible locations.
      if @current_user&.uses_rbac? && !@current_user.effective_admin?
        ids = PermissionService.new(@current_user).accessible_location_ids
        scope = ids.any? ? scope.where(location_id: ids) : scope.none
      end

      # Explicit location filter applies within the RBAC boundary above. 'all' is a
      # sentinel meaning "override the picker, no specific location" — no narrowing.
      if @filters[:location_id].present? && @filters[:location_id].to_s != 'all'
        scope = scope.for_location(@filters[:location_id])
      end

      scope.includes(:location).to_a
    end

    def lender_for(deal, vehicle, floor_plan)
      if deal
        return 'Cash' if deal.payment_type.to_s.downcase.include?('cash')
        return deal.lender_name if deal.lender_name.present?
      end
      # Floored units show the floor-plan lender when no deal lender applies.
      floor_plan ? vehicle.floor_plan_lender : vehicle.floor_plan_lender.presence
    end

    def status_label(vehicle, deal, assigned)
      (assigned ? deal.stage : vehicle.status).to_s.titleize
    end
  end
end
