# frozen_string_literal: true

module Reports
  # Read-only Inventory Stock List & GP Snapshot.
  #
  # Scoping, the deal query and the canonical GP row builder live in InventoryDealQuery
  # (shared with the Salesperson GP Pipeline report). This service adds the inventory-specific
  # inclusion rules, sectioning, funded-this-month block and meta. GP is consumed from
  # Deal#front_gross / Deal#landed_cost — never recomputed.
  class InventoryStockReportService
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
      @can_view_costs = !!can_view_costs
      @filters = (filters || {}).symbolize_keys
      @query = InventoryDealQuery.new(@company, current_user: @current_user, scope: scope,
                                      can_view_costs: @can_view_costs, filters: @filters)

      open_deals = @query.open_deals_by_vehicle

      body_rows = @query.vehicles
                        .select { |v| included_in_body?(v, open_deals[v.id] || []) }
                        .map { |v| inventory_row(v, open_deals[v.id] || []) }
      body_rows = apply_filters(body_rows)

      sections = sectionize(body_rows)
      funded = build_funded_section

      {
        meta: build_meta(sections, funded),
        sections: sections,
        funded_this_month: funded
      }
    end

    private

    # ---- Row (delegates GP/cost to the shared builder, adds section) ----------

    def inventory_row(vehicle, open_deals)
      deal = @query.resolve_open_deal(open_deals)
      # Preview shows ALL associated deals (any stage); contention count stays open-only.
      all_deals = @query.all_deals_by_vehicle[vehicle.id] || open_deals
      row = @query.build_row(vehicle, deal: deal, open_deal_count: open_deals.size, deals: all_deals)
      row[:section] = section_for(vehicle)
      row
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
        totals[:total_gp]   = rows.sum { |r| r[:calc_gp].to_d }
      end
      totals
    end

    # ---- Funded this month ---------------------------------------------------

    def build_funded_section
      deal_ids = @query.vehicles.map(&:sold_via_deal_id).compact.uniq
      return { rows: [], lender_subtotals: [], subtotal: subtotal([]) } if deal_ids.empty?

      range = Time.current.beginning_of_month..Time.current.end_of_month
      deals = @company.deals
                      .where(id: deal_ids)
                      .includes(:primary_salesperson, :secondary_salesperson, :account, :contact, :owner)
                      .index_by(&:id)

      rows = @query.vehicles.filter_map do |v|
        d = deals[v.sold_via_deal_id]
        next unless d

        funded_this_month = (d.gl_posted? && d.gl_posted_at && range.cover?(d.gl_posted_at)) ||
                            (d.stage == 'closed_won' && d.won_at && range.cover?(d.won_at))
        next unless funded_this_month

        @query.build_row(v, deal: d, open_deal_count: 0, deals: @query.all_deals_by_vehicle[v.id] || [d])
      end

      { rows: rows, lender_subtotals: lender_subtotals(rows), subtotal: subtotal(rows) }
    end

    def lender_subtotals(rows)
      rows.group_by { |r| r[:lender].presence || 'Unspecified' }.map do |lender, lrows|
        { lender: lender, **subtotal(lrows) }
      end
    end

    # ---- Filters -------------------------------------------------------------

    def apply_filters(rows)
      rows = rows.select { |r| r[:section] == @filters[:section] } if @filters[:section].present?
      rows = rows.select { |r| r[:vehicle_status] == @filters[:status] } if @filters[:status].present?
      rows = rows.select { |r| r[:salesperson_id].to_s == @filters[:salesperson_id].to_s } if @filters[:salesperson_id].present?
      rows = rows.select { |r| r[:lender].to_s.casecmp?(@filters[:lender].to_s) } if @filters[:lender].present?

      if @filters[:aging_bucket].present? && (bucket = InventoryDealQuery::AGING[@filters[:aging_bucket]])
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
        scope: @query.scope,
        filters: @filters,
        generated_at: Time.current.iso8601,
        section_subtotals: sections.map { |s| { key: s[:key], label: s[:label], **s[:subtotal] } },
        funded_lender_subtotals: funded[:lender_subtotals],
        funded_subtotal: funded[:subtotal],
        floorplan_summary: @query.floor_plan_summary,
        footnotes: FOOTNOTES
      }
    end
  end
end
