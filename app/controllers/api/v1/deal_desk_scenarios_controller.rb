# frozen_string_literal: true

module Api
  module V1
    # Deal Desk — scenario CRUD (autosave), reverse-solve, comparable units, quote
    # generation, unit transfer (gated), and the customer-facing summary PDF.
    #
    # The engine computes; the AI layer (frontend) calls solve/compare and explains.
    # Dealer gross is internal-only: scenario JSON includes it only for users with the
    # deals view_cost_details permission, and the PDF excludes it entirely.
    class DealDeskScenariosController < ApplicationController
      include ModuleAccessRequired

      before_action :set_company_scope
      require_module! 'sales.deal_desk'
      before_action :set_scenario, only: %i[show update destroy select generate_quote transfer_unit summary]

      RESOURCE = 'deal_desk'

      # GET /api/v1/deal_desk/scenarios?deal_id=&include_expired=
      def index
        return unless authorize_action!(RESOURCE, 'read')

        deal = @company.deals.find(params[:deal_id])
        scenarios = deal.deal_desk_scenarios
        scenarios = params[:include_expired].present? ? scenarios.recent : scenarios.offerable.recent

        render json: { scenarios: scenarios.map { |s| scenario_json(s) } }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end

      # GET /api/v1/deal_desk/scenarios/:id
      def show
        return unless authorize_action!(RESOURCE, 'read')

        render json: { scenario: scenario_json(@scenario) }
      end

      # POST /api/v1/deal_desk/scenarios   (autosave: persist as the rep works)
      def create
        return unless authorize_action!(RESOURCE, 'write')

        deal = @company.deals.find(params.dig(:scenario, :deal_id) || params[:deal_id])
        scenario = @company.deal_desk_scenarios.build(scenario_params)
        scenario.deal = deal
        scenario.created_by = current_user
        scenario.location_id ||= deal.location_id || Current.location_id

        snapshot_unit!(scenario)
        recompute!(scenario)

        if scenario.save
          render json: { scenario: scenario_json(scenario) }, status: :created
        else
          render json: { errors: scenario.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end

      # PATCH/PUT /api/v1/deal_desk/scenarios/:id   (autosave)
      def update
        return unless authorize_action!(RESOURCE, 'write')

        @scenario.assign_attributes(scenario_params)
        snapshot_unit!(@scenario) if @scenario.vehicle_id_changed? || @scenario.unit_price_snapshot.nil?
        recompute!(@scenario)

        if @scenario.save
          render json: { scenario: scenario_json(@scenario) }
        else
          render json: { errors: @scenario.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/deal_desk/scenarios/:id   (NEVER hard-delete — expire instead)
      def destroy
        return unless authorize_action!(RESOURCE, 'write')

        @scenario.expire!
        render json: { scenario: scenario_json(@scenario) }
      end

      # POST /api/v1/deal_desk/scenarios/:id/select
      # Marks the scenario selected and writes its structure back to the deal.
      # Does NOT touch the close / GL / commission pipeline.
      def select
        return unless authorize_action!(RESOURCE, 'write')

        @scenario.mark_selected!
        write_back_to_deal!(@scenario)
        render json: { scenario: scenario_json(@scenario) }
      end

      # POST /api/v1/deal_desk/scenarios/solve
      # Reverse-solve a lever for a target payment. Stateless calculation (Phase 1 solver).
      # Body: { deal_id, base_structure: {...}, lever: term|cash_down|price|rate, target_payment, ...opts }
      def solve
        return unless authorize_action!(RESOURCE, 'read')

        base = build_base_structure(params)
        lever = params[:lever].to_s
        target = params[:target_payment]

        result =
          if lever == 'rate'
            DealDesk::Solver.new(base).solve_by_rate(
              target_payment: target, candidates: Array(params[:candidates]).map { |c| to_h_safe(c) }
            )
          else
            opts = {}
            opts[:max_term] = params[:max_term].to_i if params[:max_term].present?
            opts[:allowed_terms] = Array(params[:allowed_terms]).map(&:to_i) if params[:allowed_terms].present?
            opts[:min_price] = params[:min_price].to_f if params[:min_price].present?
            DealDesk::Solver.solve_for_payment(base, lever: lever, target_payment: target, **opts)
          end

        render json: { solve: result }
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/deal_desk/scenarios/compare
      # Comparable-unit matching + ranking. Cross-location inclusion is visibility-only.
      # Body: { deal_id, base_structure, target_payment, include_orderable, include_other_locations, weights }
      def compare
        return unless authorize_action!(RESOURCE, 'read')

        deal = @company.deals.find(params[:deal_id])
        result = DealDesk::CompareService.new(
          company: @company, deal: deal,
          base_structure: to_h_safe(params[:base_structure]),
          target_payment: params[:target_payment],
          include_orderable: ActiveModel::Type::Boolean.new.cast(params[:include_orderable]),
          include_other_locations: ActiveModel::Type::Boolean.new.cast(params[:include_other_locations]),
          weights: to_h_safe(params[:weights])
        ).call

        render json: { compare: strip_compare_gross(result) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end

      # POST /api/v1/deal_desk/scenarios/:id/generate_quote
      # Optionally turn the selected scenario into a real Quote (reuses the quote system).
      def generate_quote
        return unless authorize_action!(RESOURCE, 'quote')

        quote = build_quote_from(@scenario)
        if quote.save
          @scenario.update(quote_id: quote.id)
          render json: { quote: { id: quote.id, quote_number: quote.quote_number,
                                  public_token: quote.public_token, public_link: quote.public_link,
                                  total: quote.total } }, status: :created
        else
          render json: { errors: quote.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/deal_desk/scenarios/:id/transfer_unit  (MANAGER ONLY)
      # The deliberately-gated action: commit a cross-location unit to this deal by moving
      # it to the deal's selling location. Reps can SEE/structure cross-location units; only
      # managers initiate the transfer.
      def transfer_unit
        return unless authorize_action!(RESOURCE, 'transfer_unit')

        unit = @company.vehicles.find_by(id: @scenario.vehicle_id)
        return render(json: { error: 'Scenario has no unit' }, status: :unprocessable_entity) unless unit

        target_location_id = @scenario.deal.location_id
        unless @scenario.is_cross_location && target_location_id.present?
          return render json: { error: 'Unit is not cross-location' }, status: :unprocessable_entity
        end

        unit.update!(location_id: target_location_id)
        @scenario.update!(is_cross_location: false, unit_location_id: target_location_id)
        render json: { scenario: scenario_json(@scenario),
                       transferred: { vehicle_id: unit.id, to_location_id: target_location_id } }
      end

      # GET /api/v1/deal_desk/scenarios/:id/summary.pdf
      def summary
        return unless authorize_action!(RESOURCE, 'read')

        pdf = DealDesk::SummaryPdfGenerator.new(@scenario).generate
        send_data pdf,
                  filename: "deal-summary-#{@scenario.id}.pdf",
                  type: 'application/pdf',
                  disposition: 'inline'
      rescue => e
        Rails.logger.error "[DealDesk PDF] #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: 'Failed to generate PDF', message: e.message }, status: :internal_server_error
      end

      private

      def set_scenario
        @scenario = @company.deal_desk_scenarios.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Scenario not found' }, status: :not_found
      end

      # company_id and computed outputs are NEVER mass-assigned.
      def scenario_params
        params.require(:scenario).permit(
          :deal_id, :vehicle_id, :label, :valid_through,
          :trade_allowance, :trade_payoff, :cash_down, :rebates,
          :lender_program_id, :lender_tier, :apr, :term_months, :tax_mode, :tax_rate,
          fees: {}, fni_products: [%i[name type price cost]]
        )
      end

      # --- Computation / snapshots -------------------------------------------
      def snapshot_unit!(scenario)
        unit = scenario.vehicle || @company.vehicles.find_by(id: scenario.vehicle_id)
        return unless unit

        scenario.unit_price_snapshot = unit.sale_price
        scenario.unit_cost_snapshot  = unit.cost || unit.dealer_cost || unit.total_cost
        scenario.unit_location_id    = unit.location_id
        scenario.unit_days_on_lot    = days_on_lot(unit)
        scenario.is_cross_location   = unit.location_id.present? &&
                                       scenario.deal&.location_id.present? &&
                                       unit.location_id != scenario.deal.location_id
      end

      def recompute!(scenario)
        resolved = DealDesk::RateResolver.resolve_with_source(
          manual_override: scenario.apr,
          company_default: @company.default_finance_rate
        )
        scenario.apr = resolved[:rate]
        scenario.rate_source = resolved[:source]&.to_s

        result = scenario.engine_result
        scenario.amount_financed = result.amount_financed
        scenario.monthly_payment = result.monthly_payment
        scenario.out_the_door    = result.out_the_door
        if result.gross
          scenario.front_gross  = result.gross.front
          scenario.back_gross   = result.gross.back
          scenario.dealer_gross = result.gross.total
        end
      end

      def build_base_structure(p)
        if p[:deal_id].present? && p[:base_structure].blank?
          deal = @company.deals.find(p[:deal_id])
          DealDesk::CompareService.new(company: @company, deal: deal).send(:default_base_structure)
            .merge(price: deal.vehicle&.sale_price.to_f, unit_cost: (deal.vehicle&.cost || deal.vehicle&.dealer_cost).to_f)
        else
          to_h_safe(p[:base_structure])
        end
      end

      # Safely coerce a param value (ActionController::Parameters, Hash, or nil) to a
      # symbol-keyed plain Hash.
      def to_h_safe(value)
        return {} if value.blank?

        (value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h).symbolize_keys
      end

      def days_on_lot(unit)
        received = unit.date_in_stock || unit.created_at
        received ? (Date.current - received.to_date).to_i : nil
      end

      # --- Write-back to the deal (structured, no close/GL side effects) ------
      def write_back_to_deal!(scenario)
        deal = scenario.deal
        attrs = {
          vehicle_id: scenario.vehicle_id,
          selling_price: scenario.unit_price_snapshot,
          trade_allowance: scenario.trade_allowance,
          trade_payoff: scenario.trade_payoff,
          down_payment: scenario.cash_down,
          doc_fee: scenario.fees&.dig('doc'),
          financed_amount: scenario.amount_financed
        }.compact
        deal.update(attrs)
      end

      # --- Quote generation ---------------------------------------------------
      def build_quote_from(scenario)
        deal = scenario.deal
        @company.quotes.new(
          deal_id: deal.id, account_id: deal.account_id, contact_id: deal.contact_id,
          vehicle_id: scenario.vehicle_id&.to_s, location_id: scenario.location_id,
          sales_rep_id: current_user.id, status: 'draft', valid_until: scenario.valid_through,
          notes: "Generated from Deal Desk scenario ##{scenario.id}",
          items: quote_items_from(scenario)
        )
      end

      # Customer-safe line items — NO gross/cost.
      def quote_items_from(scenario)
        items = [{ 'description' => 'Selling Price', 'quantity' => 1, 'unit_price' => scenario.unit_price_snapshot.to_f }]
        (scenario.fees || {}).each do |k, v|
          items << { 'description' => "#{k.to_s.titleize} Fee", 'quantity' => 1, 'unit_price' => v.to_f } if v.to_f.positive?
        end
        Array(scenario.fni_products).each do |p|
          p = p.symbolize_keys
          items << { 'description' => p[:name].to_s, 'quantity' => 1, 'unit_price' => p[:price].to_f }
        end
        items
      end

      # --- Serialization (gross gated) ---------------------------------------
      def scenario_json(scenario)
        base = {
          id: scenario.id, deal_id: scenario.deal_id, vehicle_id: scenario.vehicle_id,
          label: scenario.label, status: scenario.status,
          valid_through: scenario.valid_through, selected_at: scenario.selected_at,
          trade_allowance: scenario.trade_allowance, trade_payoff: scenario.trade_payoff,
          cash_down: scenario.cash_down, rebates: scenario.rebates,
          fees: scenario.fees, fni_products: scenario.fni_products,
          lender_program_id: scenario.lender_program_id, lender_tier: scenario.lender_tier,
          apr: scenario.apr, rate_source: scenario.rate_source, term_months: scenario.term_months,
          tax_mode: scenario.tax_mode, tax_rate: scenario.tax_rate,
          unit_price_snapshot: scenario.unit_price_snapshot, price_changed: scenario.price_changed?,
          amount_financed: scenario.amount_financed, monthly_payment: scenario.monthly_payment,
          out_the_door: scenario.out_the_door,
          unit_location_id: scenario.unit_location_id, unit_days_on_lot: scenario.unit_days_on_lot,
          is_cross_location: scenario.is_cross_location,
          quote_id: scenario.quote_id, created_by_id: scenario.created_by_id,
          created_at: scenario.created_at, updated_at: scenario.updated_at
        }
        if can_view_costs?
          base.merge!(front_gross: scenario.front_gross, back_gross: scenario.back_gross,
                      dealer_gross: scenario.dealer_gross, unit_cost_snapshot: scenario.unit_cost_snapshot)
        end
        base
      end

      def strip_compare_gross(result)
        return result if can_view_costs?

        result = result.deep_dup
        result[:anchor]&.delete(:dealer_gross)
        Array(result[:candidates]).each { |c| c.delete(:dealer_gross) }
        result
      end

      # Reuses the deals cost-visibility permission (gross is a finance concern).
      def can_view_costs?
        return @can_view_costs if defined?(@can_view_costs)

        @can_view_costs = current_user&.has_permission?('deals', 'read', scope: 'view_cost_details') || false
      end
    end
  end
end
