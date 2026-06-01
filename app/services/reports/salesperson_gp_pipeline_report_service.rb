# frozen_string_literal: true

module Reports
  # Read-only Salesperson GP Pipeline report ("Cheat Sheet").
  #
  # Reuses InventoryDealQuery for scoping, the deal query and the canonical GP row builder
  # (shared with the Inventory Stock List report) — GP is consumed from Deal#front_gross,
  # never recomputed. Rows are grouped by primary_salesperson (full GP credit to primary);
  # a secondary salesperson is shown as a split indicator only.
  #
  # Per-rep GP pipeline states:
  #   Pending          = open deals
  #   Closed Not Funded = closed_won AND NOT gl_posted (and not funded this month)
  #   Funded           = gl_posted this month, or closed_won with actual_close_date this month
  class SalespersonGpPipelineReportService
    CLOSED_STAGE = 'closed_won'

    FOOTNOTES = [
      'GP is pre-commission (front-end gross), read from the unified Deal#front_gross — never recomputed.',
      'Full GP credit goes to the primary salesperson; a secondary salesperson is a split indicator only.',
      'Funded = closing entries posted to the GL this month. Once a deal is approved by the accountant and posted to the GL, it is recorded here as Funded. Closed Not Funded = closed_won but not yet approved/GL-posted.',
      'Note: "Funded" reflects GL posting (accountant approval), not a confirmed lender disbursement. A future enhancement may add a separate lender-funded flag to distinguish actual lender funding.',
      'Total Pending = Closed Not Funded + Pending. Funded + Pending = Funded + Total Pending.',
      'COST/GP columns and the GP summary are hidden without deals:read:view_cost_details.',
      'Funded This Month is grouped by location (toggle: lender).'
    ].freeze

    def initialize(company, current_user: nil)
      @company = company
      @current_user = current_user
    end

    # @param scope [String] 'inventory' (current selector) or 'accounting' (all company locations)
    # @param can_view_costs [Boolean] gates cost/GP columns AND the GP summary
    # @param filters [Hash] salesperson_id, location_id, lender, status, aging_bucket (off by default)
    def generate(scope: 'inventory', can_view_costs: false, filters: {})
      @can_view_costs = !!can_view_costs
      @filters = (filters || {}).symbolize_keys
      @query = InventoryDealQuery.new(@company, current_user: @current_user, scope: scope,
                                      can_view_costs: @can_view_costs, filters: @filters)
      @month = Date.current.beginning_of_month..Date.current.end_of_month

      entries = apply_filters(collect_entries)
      groups = build_groups(entries)

      {
        meta: build_meta,
        summary: @can_view_costs ? build_summary(groups) : nil,
        groups: groups.map { |g| present_group(g) },
        funded_this_month: build_funded(entries)
      }
    end

    private

    # Each entry: { deal:, vehicle:, state:, row:, gp: } where gp is the unified Deal#front_gross.
    def collect_entries
      entries = []

      # Pending — one row per open deal (contention surfaced via open_deal_count).
      @query.open_deals_by_vehicle.each do |vehicle_id, open_deals|
        vehicle = @query.vehicles_by_id[vehicle_id]
        next unless vehicle

        open_deals.each { |d| entries << make_entry(vehicle, d, :pending, open_deals.size) }
      end

      # Closed / Funded — closed_won deals on in-scope vehicles.
      @query.deals_for_vehicles(stages: [CLOSED_STAGE]).each do |d|
        vehicle = @query.vehicles_by_id[d.vehicle_id]
        next unless vehicle

        state = classify_closed(d)
        entries << make_entry(vehicle, d, state, 0) if state
      end

      entries
    end

    def make_entry(vehicle, deal, state, open_deal_count)
      row = @query.build_row(vehicle, deal: deal, open_deal_count: open_deal_count)
      row[:offline] = row[:offline] || 'Not Ord' # deal exists but not yet scheduled/ordered
      row[:serial_last5] = row[:serial_or_stock].to_s.last(5).presence
      row[:pipeline_state] = state.to_s
      row[:split] = deal.secondary_salesperson_id.present?
      { deal: deal, vehicle: vehicle, state: state, row: row, gp: deal.front_gross }
    end

    # Funded = closing entries posted to the GL this month (accountant approval = money
    # recognized). Lifecycle: closed_won -> accountant approves & posts to GL (gl_posted)
    # -> Funded. Closed-Not-Funded is the GL-approval gap. A closed_won deal that is NOT
    # gl_posted is ALWAYS Closed-Not-Funded regardless of close date; the close date no
    # longer determines funded.
    def classify_closed(deal)
      return :funded if deal.gl_posted? && in_month?(deal.gl_posted_at)
      return :closed_not_funded if deal.stage == CLOSED_STAGE && !deal.gl_posted? # closed, awaiting GL approval/posting

      nil # gl_posted in a prior month -> historical, out of the current pipeline
    end

    def in_month?(date_or_time)
      date_or_time && @month.cover?(date_or_time.to_date)
    end

    # ---- Grouping by primary salesperson ------------------------------------

    def build_groups(entries)
      entries.group_by { |e| e[:deal].primary_salesperson_id }.map do |sp_id, es|
        { salesperson_id: sp_id,
          salesperson: @query.salesperson_name(es.first[:deal].primary_salesperson) || 'Unassigned',
          entries: es }
      end.sort_by { |g| g[:salesperson].to_s }
    end

    def present_group(group)
      out = {
        salesperson_id: group[:salesperson_id],
        salesperson: group[:salesperson],
        count: group[:entries].size,
        rows: group[:entries].map { |e| e[:row] }
      }
      out[:summary] = rep_summary(group[:entries]) if @can_view_costs
      out
    end

    # ---- GP pipeline summary -------------------------------------------------

    def rep_summary(entries)
      funded  = sum_gp(entries, :funded)
      cnf     = sum_gp(entries, :closed_not_funded)
      pending = sum_gp(entries, :pending)
      total_pending = cnf + pending
      {
        funded: funded,
        closed_not_funded: cnf,
        pending: pending,
        total_pending: total_pending,
        funded_plus_pending: funded + total_pending
      }
    end

    def sum_gp(entries, state)
      entries.select { |e| e[:state] == state }.sum { |e| e[:gp].to_d }
    end

    def build_summary(groups)
      per_rep = groups.map do |g|
        { salesperson_id: g[:salesperson_id], salesperson: g[:salesperson], **rep_summary(g[:entries]) }
      end
      keys = %i[funded closed_not_funded pending total_pending funded_plus_pending]
      total = keys.index_with { |k| per_rep.sum { |r| r[k].to_d } }
      { per_rep: per_rep, total: total }
    end

    # ---- Funded this month (grouped by location by default; lender toggle) ----
    # Location is the operating-entity grouping for a multi-location dealer (no selling-
    # entity model exists). Keyed by a STABLE location_id (not the display string) so
    # duplicate location names never collide; location_name carries the display label.
    def build_funded(entries)
      funded = entries.select { |e| e[:state] == :funded }
      group_by = @filters[:funded_group_by].to_s == 'lender' ? 'lender' : 'location'

      groups =
        if group_by == 'lender'
          funded.group_by { |e| e[:row][:lender].presence || 'Unspecified' }
                .map { |lender, es| funded_group(lender, lender, es) }
        else
          funded.group_by { |e| e[:vehicle]&.location_id }
                .map { |loc_id, es| funded_group(loc_id, es.first[:row][:location].presence || 'Unassigned location', es) }
        end

      { group_by: group_by, groups: groups, count: funded.size }
    end

    def funded_group(key, label, entries)
      h = { key: key, label: label, count: entries.size, total_price: entries.sum { |e| e[:row][:price].to_d } }
      h[:total_gp] = entries.sum { |e| e[:gp].to_d } if @can_view_costs
      h
    end

    # ---- Filters (all off by default) ---------------------------------------

    def apply_filters(entries)
      if @filters[:salesperson_id].present?
        entries = entries.select { |e| e[:deal].primary_salesperson_id.to_s == @filters[:salesperson_id].to_s }
      end
      if @filters[:lender].present?
        entries = entries.select { |e| e[:row][:lender].to_s.casecmp?(@filters[:lender].to_s) }
      end
      if @filters[:status].present?
        entries = entries.select do |e|
          e[:row][:pipeline_state] == @filters[:status] || e[:row][:vehicle_status] == @filters[:status]
        end
      end
      if @filters[:aging_bucket].present? && (bucket = InventoryDealQuery::AGING[@filters[:aging_bucket]])
        entries = entries.select { |e| e[:row][:age_days] && bucket.cover?(e[:row][:age_days]) }
      end
      entries
    end

    def build_meta
      {
        can_view_costs: @can_view_costs,
        scope: @query.scope,
        filters: @filters,
        generated_at: Time.current.iso8601,
        footnotes: FOOTNOTES
      }
    end
  end
end
