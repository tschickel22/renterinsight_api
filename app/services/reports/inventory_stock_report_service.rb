# frozen_string_literal: true

module Reports
  # Read-only Inventory Stock List & GP Snapshot.
  #
  # CONSUMES the unified GP method — for assigned (deal) units, EST GP is read straight
  # from Deal#front_gross and cost from Deal#landed_cost; GP is NEVER recomputed here.
  # For available (no-deal) units there is no Deal, so the estimate is price − vehicle
  # structured cost (the same arithmetic a deal at that price would yield). Vehicle
  # structured cost is the single cost source. Missing cost is flagged, never guessed.
  class InventoryStockReportService
    OPEN_STAGES = %w[prospecting qualification needs_analysis proposal negotiation closing].freeze
    DEFAULT_PIPELINE = OPEN_STAGES

    AGING_BUCKETS = {
      '0-30'  => (0..30),
      '31-60' => (31..60),
      '61-90' => (61..90),
      '90+'   => (91..Float::INFINITY)
    }.freeze

    # Section render order. Only sections with rows are emitted.
    SECTION_DEFS = [
      ['new_single',       'New — Single Section'],
      ['new_double',       'New — Double Section'],
      ['new_unspecified',  'New — Section Count Not Entered'],
      ['used_single',      'Used — Single Section'],
      ['used_double',      'Used — Double Section'],
      ['used_unspecified', 'Used — Section Count Not Entered'],
      ['consignment',      'Consignment'],
      ['land_home',        'Land-Home'],
      ['site_built',       'Site-Built']
    ].freeze

    FOOTNOTES = [
      'GP is pre-commission (front-end gross).',
      'Assigned units use the deal selling price and the unified Deal#front_gross; available units estimate price − vehicle cost.',
      'COST is the unified landed cost (vehicle structured cost + deal-level costs). Shown as "—" when cost has not been entered.',
      'When a unit has multiple open deals, the most advanced deal (by pipeline stage, then most recent) is shown; open_deal_count reflects the total.',
      'Location reflects the current selector unless an explicit location filter is applied.',
      'Floor-plan interest and delivery/setup are period costs included in the GP margin view but not in COGS.'
    ].freeze

    def initialize(company, current_user: nil)
      @company = company
      @current_user = current_user
    end

    # @param scope [String] 'inventory' (current selector) or 'accounting' (all company locations)
    # @param can_view_costs [Boolean] gates cost/GP columns (deals:read:view_cost_details)
    # @param filters [Hash] location_id, section, status, salesperson_id, lender, aging_bucket, search
    def generate(scope: 'inventory', can_view_costs: false, filters: {})
      @scope = scope.to_s == 'accounting' ? 'accounting' : 'inventory'
      @can_view_costs = !!can_view_costs
      @filters = (filters || {}).symbolize_keys

      vehicles = base_vehicle_scope
      open_deals = open_deals_by_vehicle(vehicles)

      body_rows = vehicles
                  .select { |v| included_in_body?(v, open_deals[v.id] || []) }
                  .map { |v| build_row(v, open_deals[v.id] || []) }
      body_rows = apply_filters(body_rows)

      sections = sectionize(body_rows)
      funded = build_funded_section(vehicles)

      {
        meta: build_meta(sections, funded),
        sections: sections,
        funded_this_month: funded
      }
    end

    private

    # ---- Scoping -------------------------------------------------------------

    def base_vehicle_scope
      scope = @company.vehicles.where(is_deleted: [false, nil])

      # scope param: inventory honours the current location selector; accounting spans
      # all company locations.
      scope = scope.for_current_location if @scope == 'inventory'

      # ALWAYS enforce RBAC location filtering: company-tier admins see all; location-tier
      # users are restricted to their accessible locations.
      if @current_user&.uses_rbac? && !@current_user.effective_admin?
        ids = PermissionService.new(@current_user).accessible_location_ids
        scope = ids.any? ? scope.where(location_id: ids) : scope.none
      end

      # Explicit location filter applies within the RBAC boundary above.
      scope = scope.for_location(@filters[:location_id]) if @filters[:location_id].present?

      scope.includes(:location).to_a
    end

    def open_deals_by_vehicle(vehicles)
      ids = vehicles.map(&:id)
      return {} if ids.empty?

      @company.deals
              .where(vehicle_id: ids, stage: OPEN_STAGES, deleted_at: nil)
              .includes(:primary_salesperson, :account, :contact, :owner)
              .group_by(&:vehicle_id)
    end

    # ---- Inclusion -----------------------------------------------------------

    def included_in_body?(vehicle, open_deals)
      status = vehicle.status
      return true if %w[available reserved pending].include?(status)
      return true if open_deals.any? # any status with an open deal
      return vehicle.sold_via_deal_id.present? if status == 'available_to_order' # + funded
      return vehicle.sold_via_deal_id.blank? if status == 'sold' # sold AND no deal

      false # available_to_order with no deal, and everything else
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

    def resolve_open_deal(open_deals)
      return nil if open_deals.empty?

      # Most advanced stage wins; tie-break on most recent.
      open_deals.max_by { |d| [stage_rank(d.stage), d.created_at || Time.at(0)] }
    end

    # ---- Row building --------------------------------------------------------

    # deal: explicit deal (used for the funded section); otherwise the resolved open deal.
    def build_row(vehicle, open_deals, deal: nil)
      resolved = deal || resolve_open_deal(open_deals)
      assigned = resolved.present?
      status = vehicle.status
      flags = []

      on_order = status == 'available_to_order'
      flags << 'on_order' if on_order

      sold_no_deal = status == 'sold' && !assigned && vehicle.sold_via_deal_id.blank?
      flags << 'no_deal' if sold_no_deal

      cost = assigned ? resolved.landed_cost : vehicle.structured_cost
      cost_missing = cost.nil?
      flags << 'cost_not_entered' if cost_missing && !sold_no_deal

      price = if sold_no_deal
                nil
              elsif assigned
                resolved.selling_price
              else
                vehicle.total_home_price
              end

      est_gp = if sold_no_deal || cost_missing || price.nil?
                 nil # GP "—"
               elsif assigned
                 resolved.front_gross # CONSUME unified GP — never recompute
               else
                 (price.to_d - cost.to_d).round(2)
               end

      gp_pct = (est_gp && price && price.to_d > 0) ? ((est_gp.to_d / price.to_d) * 100).round(2) : nil

      age = on_order ? nil : (vehicle.date_in_stock ? (Date.current - vehicle.date_in_stock.to_date).to_i : nil)
      fp = floor_plan_index[vehicle.id]

      row = {
        vehicle_id: vehicle.id,
        serial_or_stock: vehicle.stock_number.presence || vehicle.serial_number,
        location: vehicle.location&.name || 'Unassigned location',
        age_days: age,
        customer: assigned ? resolved.customer_display_name : nil,
        salesperson: assigned ? salesperson_name(resolved) : nil,
        salesperson_id: assigned ? resolved.primary_salesperson_id : nil,
        deposit: assigned ? resolved.down_payment : nil,
        price: price,
        addon_gross: assigned ? resolved.addon_gross : nil,
        lender: lender_for(resolved, vehicle, fp),
        status: status_label(vehicle, resolved, assigned),
        vehicle_status: status,
        open_deal_count: open_deals.size,
        manufacturer: vehicle.make,
        model: vehicle.model,
        year: vehicle.year,
        sections: vehicle.sections,
        bedrooms: vehicle.bedrooms,
        bathrooms: vehicle.bathrooms,
        condition: vehicle.condition,
        flags: flags,
        floorplan: fp && {
          principal: fp[:principal],
          lender: fp[:lender],
          days_on_plan: fp[:days_on_plan],
          accrued_interest: fp[:accrued_interest],
          monthly_interest_estimate: fp[:monthly_interest_estimate]
        },
        section: section_for(vehicle)
      }

      # Cost/GP columns are omitted entirely when the user lacks view_cost_details.
      if @can_view_costs
        row[:cost] = cost
        row[:est_gp] = est_gp
        row[:gp_pct] = gp_pct
      end

      row
    end

    def salesperson_name(deal)
      u = deal.primary_salesperson
      return nil unless u

      [u.try(:first_name), u.try(:last_name)].compact.join(' ').strip.presence || u.try(:email)
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

    # ---- Sectioning ----------------------------------------------------------

    def section_for(vehicle)
      cond = vehicle.condition.to_s
      return 'consignment' if cond == 'consignment'
      return 'land_home' if vehicle.location_type.to_s == 'land_home'
      return 'site_built' if vehicle.dwelling_type.to_s == 'site_built'

      size = if vehicle.sections.to_i >= 2 then 'double'
             elsif vehicle.sections.to_i == 1 then 'single'
             else 'unspecified'
             end
      base = %w[new used].include?(cond) ? cond : 'new'
      "#{base}_#{size}"
    end

    def sectionize(rows)
      grouped = rows.group_by { |r| r[:section] }
      SECTION_DEFS.filter_map do |key, label|
        section_rows = grouped[key]
        next if section_rows.blank?

        { key: key, label: label, rows: section_rows, subtotal: subtotal(section_rows) }
      end
    end

    def subtotal(rows)
      totals = {
        count: rows.size,
        total_price: rows.sum { |r| r[:price].to_d }
      }
      if @can_view_costs
        totals[:total_cost] = rows.sum { |r| r[:cost].to_d }
        totals[:total_gp]   = rows.sum { |r| r[:est_gp].to_d }
      end
      totals
    end

    # ---- Funded this month ---------------------------------------------------

    def build_funded_section(vehicles)
      deal_ids = vehicles.map(&:sold_via_deal_id).compact.uniq
      return { rows: [], lender_subtotals: [], subtotal: subtotal([]) } if deal_ids.empty?

      range = Time.current.beginning_of_month..Time.current.end_of_month
      deals = @company.deals
                      .where(id: deal_ids)
                      .includes(:primary_salesperson, :account, :contact, :owner)
                      .index_by(&:id)

      rows = vehicles.filter_map do |v|
        d = deals[v.sold_via_deal_id]
        next unless d

        funded_this_month = (d.gl_posted? && d.gl_posted_at && range.cover?(d.gl_posted_at)) ||
                            (d.stage == 'closed_won' && d.won_at && range.cover?(d.won_at))
        next unless funded_this_month

        build_row(v, [], deal: d)
      end

      { rows: rows, lender_subtotals: lender_subtotals(rows), subtotal: subtotal(rows) }
    end

    def lender_subtotals(rows)
      rows.group_by { |r| r[:lender].presence || 'Unspecified' }.map do |lender, lrows|
        { lender: lender, **subtotal(lrows) }
      end
    end

    # ---- Floor plan ----------------------------------------------------------

    def floor_plan_report
      @floor_plan_report ||= Accounting::FloorPlanService.new(@company).report(location_id: @filters[:location_id].presence)
    end

    def floor_plan_index
      @floor_plan_index ||= floor_plan_report[:vehicles].index_by { |r| r[:vehicle_id] }
    end

    # ---- Filters -------------------------------------------------------------

    def apply_filters(rows)
      rows = rows.select { |r| r[:section] == @filters[:section] } if @filters[:section].present?
      rows = rows.select { |r| r[:vehicle_status] == @filters[:status] } if @filters[:status].present?
      rows = rows.select { |r| r[:salesperson_id].to_s == @filters[:salesperson_id].to_s } if @filters[:salesperson_id].present?
      rows = rows.select { |r| r[:lender].to_s.casecmp?(@filters[:lender].to_s) } if @filters[:lender].present?

      if @filters[:aging_bucket].present? && (bucket = AGING_BUCKETS[@filters[:aging_bucket]])
        rows = rows.select { |r| r[:age_days] && bucket.cover?(r[:age_days]) }
      end

      if @filters[:search].present?
        q = @filters[:search].to_s.downcase
        rows = rows.select do |r|
          [r[:serial_or_stock], r[:manufacturer], r[:model], r[:customer]]
            .compact.any? { |v| v.to_s.downcase.include?(q) }
        end
      end

      rows
    end

    # ---- Meta ----------------------------------------------------------------

    def build_meta(sections, funded)
      {
        can_view_costs: @can_view_costs,
        scope: @scope,
        filters: @filters,
        generated_at: Time.current.iso8601,
        section_subtotals: sections.map { |s| { key: s[:key], label: s[:label], **s[:subtotal] } },
        funded_lender_subtotals: funded[:lender_subtotals],
        funded_subtotal: funded[:subtotal],
        floorplan_summary: floor_plan_report[:summary],
        footnotes: FOOTNOTES
      }
    end
  end
end
