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
                .where(vehicle_id: vehicle_ids, stage: OPEN_STAGES, deleted_at: nil)
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

    # Most advanced open deal wins; tie-break on most recent.
    def resolve_open_deal(open_deals)
      return nil if open_deals.blank?

      open_deals.max_by { |d| [stage_rank(d.stage), d.created_at || Time.at(0)] }
    end

    # ---- Canonical row (consumes unified GP) --------------------------------

    # deal: the assigned deal (resolved open deal, or an explicit closed/funded deal).
    # open_deal_count: number of open deals on the vehicle (contention indicator).
    def build_row(vehicle, deal: nil, open_deal_count: 0)
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
        serial_or_stock: vehicle.stock_number.presence || vehicle.serial_number,
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
        }
      }

      # Cost/GP columns are omitted entirely when the user lacks view_cost_details.
      if @can_view_costs
        row[:cost] = cost
        row[:calc_gp] = calc_gp
        row[:gp_pct] = gp_pct
      end

      row
    end

    def salesperson_name(user)
      return nil unless user

      [user.try(:first_name), user.try(:last_name)].compact.join(' ').strip.presence || user.try(:email)
    end

    # ---- Floor plan ----------------------------------------------------------

    def floor_plan_report
      @floor_plan_report ||= Accounting::FloorPlanService.new(@company).report(location_id: @filters[:location_id].presence)
    end

    def floor_plan_index
      @floor_plan_index ||= floor_plan_report[:vehicles].index_by { |r| r[:vehicle_id] }
    end

    def floor_plan_summary
      floor_plan_report[:summary]
    end

    private

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
