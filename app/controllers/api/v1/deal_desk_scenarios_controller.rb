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
      before_action :set_scenario, only: %i[show update destroy select apply apply_unit_swap revert_unit_swap generate_quote transfer_unit summary]

      RESOURCE = 'deal_desk'

      # GET /api/v1/deal_desk/scenarios?deal_id=&include_expired=
      def index
        return unless authorize_action!(RESOURCE, 'read')

        deal = @company.deals.find(params[:deal_id])
        scenarios = deal.deal_desk_scenarios
        scenarios = params[:include_expired].present? ? scenarios.recent : scenarios.offerable.recent

        # Surface the company's write-back timing so the desk workspace is mode-aware without
        # a separate round-trip (and without needing company_settings permission — this list
        # is gated on deal_desk:read). on_close => the desk shows "applies at close"; on_apply
        # => the rep must explicitly apply.
        render json: {
          scenarios: scenarios.map { |s| scenario_json(s) },
          deal_desk_writeback_mode: @company.deal_desk_writeback_mode,
          # Phase 5 unit-swap affordances: the FE shows "Apply unit swap" when the open
          # scenario's vehicle differs from the deal's, and "Revert to original unit" when a
          # baseline exists (a swap was applied). gl_posted disables both (server also guards).
          deal_vehicle_id: deal.vehicle_id,
          deal_has_swap_baseline: deal.deal_desk_baseline.present?,
          deal_gl_posted: deal.gl_posted?
        }
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
        scenario.vehicle_id ||= deal.vehicle_id

        snapshot_unit!(scenario)
        scenario.snapshot_line_items_from_deal!(deal)
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

        # Capture the unit BEFORE assignment so a swap can drop the OLD home's packages.
        old_vehicle_id = @scenario.vehicle_id
        @scenario.assign_attributes(scenario_params)

        if @scenario.vehicle_id_changed?
          snapshot_unit!(@scenario)
          # Unit swap: drop the old home's packages, pull the new unit's (deal add-ons +
          # fees + F&I persist). Display + payment math only — nothing pushed to the deal
          # (that's the deferred Phase 5 unit-swap write-back).
          @scenario.resync_line_items_for_unit!(old_vehicle_id)
        elsif @scenario.unit_price_snapshot.nil?
          snapshot_unit!(@scenario)
        end
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
      # Flags the scenario selected (single-selection per deal — see mark_selected!) and
      # stamps selected_at. Does NOT write back to the deal: selecting-to-print a pencil
      # must not mutate the live deal's economics before close. Use #apply for that.
      def select
        return unless authorize_action!(RESOURCE, 'write')

        @scenario.mark_selected!
        render json: { scenario: scenario_json(@scenario) }
      end

      # POST /api/v1/deal_desk/scenarios/:id/apply
      # The deliberate "apply this structure to the deal" step: writes the scenario's
      # vehicle/price/trade/down/doc-fee/financed amount back to the live deal. Separate
      # from #select so printing a pencil never mutates the deal (Section 25: the binding
      # write-back happens at CLOSE via the deal-close → GL-approval pipeline). Kept callable
      # pre-close, but it is always the explicit mutate-the-deal action — never auto-run.
      def apply
        return unless authorize_action!(RESOURCE, 'write')

        @scenario.write_back_to_deal!
        # Add-only merge of the scenario's line items + F&I onto the deal as deal_products, so
        # the edit-deal and approval forms reflect what was sold. Never touches the home line.
        changes = @scenario.merge_line_items_and_fni_to_deal!
        render json: {
          scenario: scenario_json(@scenario),
          applied: true,
          added_count: changes[:added].size,
          updated_count: changes[:updated_qty].size,
          skipped_count: changes[:skipped],
          added: changes[:added],
          updated_qty: changes[:updated_qty]
        }
      end

      # POST /api/v1/deal_desk/scenarios/:id/apply_unit_swap   (MANAGER ONLY)
      # The destructive, deliberate "swap this unit onto the deal now" action (Phase 5). Distinct
      # from #apply (which only merges line items/F&I, never the home). Captures an immutable
      # baseline on first swap so #revert_unit_swap can restore the original. Blocked once the
      # deal is GL-posted — swapping after the GL post would desync posted COGS/inventory.
      def apply_unit_swap
        return unless authorize_action!(RESOURCE, 'swap_unit')

        deal = @scenario.deal
        if deal.gl_posted?
          return render json: { error: 'Cannot swap unit: deal is already posted to the GL' }, status: :unprocessable_entity
        end

        result = @scenario.apply_unit_swap_to_deal!
        render json: { scenario: scenario_json(@scenario), swap: result }
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      rescue => e
        Rails.logger.error "[DealDesk swap] #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: 'Unit swap failed', message: e.message }, status: :internal_server_error
      end

      # POST /api/v1/deal_desk/scenarios/:id/revert_unit_swap   (MANAGER ONLY)
      # Undo a previously-applied swap, restoring the deal's captured baseline (single-level
      # revert-to-origin). Same gate + GL guard as apply_unit_swap.
      def revert_unit_swap
        return unless authorize_action!(RESOURCE, 'swap_unit')

        deal = @scenario.deal
        if deal.gl_posted?
          return render json: { error: 'Cannot revert swap: deal is already posted to the GL' }, status: :unprocessable_entity
        end

        result = @scenario.revert_unit_swap_on_deal!
        render json: { scenario: scenario_json(@scenario), revert: result }
      rescue => e
        Rails.logger.error "[DealDesk revert] #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: 'Unit swap revert failed', message: e.message }, status: :internal_server_error
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

      # POST /api/v1/deal_desk/scenarios/ai_solve
      # Conversational solve. The AI interprets the prompt and explains; the ENGINE computes
      # every figure (reuses Solver/Engine/CompareService — the LLM never produces a number).
      # Body: { deal_id, scenario_id?, prompt }
      def ai_solve
        return unless authorize_action!(RESOURCE, 'read')

        deal = @company.deals.find(params[:deal_id])
        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
        result = DealDesk::AiSolveService.new(
          company: @company, deal: deal,
          base_structure: ai_base_structure(deal),
          prompt: params[:prompt].to_s,
          can_view_costs: can_view_costs?,
          api_key: api_key,
          user: current_user
        ).call

        render json: result
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
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

      # POST /api/v1/deal_desk/scenarios/grid
      # Payment matrix (the "four-square" grid): every cell is computed by the SAME engine
      # solve/compare use — one Engine.compute per (term_months, cash_down) pair. No new math,
      # no LLM. dealer_gross is attached per cell only for cost-viewers.
      # Body: { deal_id, base_structure?, terms: [number], cash_downs: [number] }
      MAX_GRID_CELLS = 64

      def grid
        return unless authorize_action!(RESOURCE, 'read')

        terms      = Array(params[:terms]).map(&:to_i).reject(&:zero?)
        cash_downs = Array(params[:cash_downs]).map(&:to_f)
        return render(json: { error: 'terms and cash_downs are required' }, status: :unprocessable_entity) if terms.empty? || cash_downs.empty?

        if terms.length * cash_downs.length > MAX_GRID_CELLS
          return render json: { error: "Matrix too large: #{terms.length}x#{cash_downs.length} exceeds #{MAX_GRID_CELLS} cells" },
                        status: :unprocessable_entity
        end

        base = build_base_structure(params)
        cells = terms.flat_map do |term|
          cash_downs.map { |cash_down| grid_cell(base, term, cash_down) }
        end

        render json: { grid: { terms: terms, cash_downs: cash_downs, cells: cells } }
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
          :lender_program_id, :lender_tier, :apr, :apr_override, :term_months, :tax_mode, :tax_rate,
          fees: {}, fni_products: [%i[name type price cost]]
        )
      end

      # --- Computation / snapshots -------------------------------------------
      def snapshot_unit!(scenario)
        unit = scenario.vehicle || @company.vehicles.find_by(id: scenario.vehicle_id)
        return unless unit

        # Price source depends on whether this scenario's unit is still the DEAL's home or a
        # swapped-in comparable:
        #   - Same as the deal's home  -> prefer the deal's selling_price ("counted via the
        #     line"), so the snapshot tracks what was actually quoted and avoids drift between
        #     vehicle.sale_price and the deal_product price.
        #   - A different (swapped) unit -> the deal's selling_price belongs to the OLD home,
        #     so it must NOT be used. Snapshot the swapped unit's own sale_price instead, or
        #     the recap/grid would keep computing off the original home's price.
        is_deal_home  = scenario.deal&.vehicle_id.present? && scenario.vehicle_id == scenario.deal.vehicle_id
        deal_selling  = scenario.deal&.selling_price
        scenario.unit_price_snapshot =
          if is_deal_home && deal_selling.present? && deal_selling.to_f.positive?
            deal_selling
          else
            unit.sale_price
          end
        # Cost stays from the vehicle — the deal/home line cost is unreliable (0/garbage).
        scenario.unit_cost_snapshot  = unit.cost || unit.dealer_cost || unit.total_cost
        scenario.unit_location_id    = unit.location_id
        scenario.unit_days_on_lot    = days_on_lot(unit)
        scenario.is_cross_location   = unit.location_id.present? &&
                                       scenario.deal&.location_id.present? &&
                                       unit.location_id != scenario.deal.location_id
      end

      def recompute!(scenario)
        # Resolve the selected lender tier's rate (precedence: manual_override > tier > company_default,
        # handled inside RateResolver). nil when no program/tier is selected or the tier can't be found.
        tier_rate = nil
        if scenario.lender_program_id.present? && scenario.lender_tier.present?
          tier = scenario.lender_program&.tiers&.detect { |t| t.tier_label == scenario.lender_tier }
          tier_rate = tier&.rate
        end

        # apr_override = the rep-typed manual override (input); apr = the resolved rate (computed output).
        # Keeping them in separate columns avoids re-reading a resolved rate as a manual override.
        resolved = DealDesk::RateResolver.resolve_with_source(
          manual_override: scenario.apr_override,
          tier_rate: tier_rate,
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

      # Base structure for AI solve: from an existing scenario's snapshot if given,
      # otherwise derived from the deal (incl. the deal's unit price/cost).
      def ai_base_structure(deal)
        if params[:scenario_id].present?
          @company.deal_desk_scenarios.find(params[:scenario_id]).engine_inputs
        else
          build_base_structure(deal_id: deal.id)
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

      # One payment-grid cell: the base structure with this (term, cash_down) pair swapped in,
      # run through the SAME Engine.compute used everywhere else. Gross gated to cost-viewers.
      def grid_cell(base, term, cash_down)
        res = DealDesk::Engine.compute(base.merge(term_months: term, cash_down: cash_down))
        cell = {
          term_months: res.term_months,
          cash_down: cash_down,
          monthly_payment: res.monthly_payment,
          amount_financed: res.amount_financed,
          out_the_door: res.out_the_door
        }
        cell[:dealer_gross] = res.gross&.total if can_view_costs? && res.gross
        cell
      end

      def days_on_lot(unit)
        received = unit.date_in_stock || unit.created_at
        received ? (Date.current - received.to_date).to_i : nil
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
          trade_allowance: scenario.trade_allowance&.to_f, trade_payoff: scenario.trade_payoff&.to_f,
          cash_down: scenario.cash_down&.to_f, rebates: scenario.rebates&.to_f,
          fees: scenario.fees, fni_products: scenario.fni_products,
          # Price-only for ALL users — cost/margin are gated behind can_view_costs? below
          # (same treatment as front_gross/dealer_gross). Never ship per-line cost here.
          line_items: Array(scenario.line_items).map do |li|
            li = li.symbolize_keys
            { description: li[:description], price: li[:price].to_f, quantity: (li[:quantity] || 1) }
          end,
          lender_program_id: scenario.lender_program_id, lender_tier: scenario.lender_tier,
          apr: scenario.apr&.to_f, apr_override: scenario.apr_override&.to_f,
          rate_source: scenario.rate_source, term_months: scenario.term_months,
          tax_mode: scenario.tax_mode, tax_rate: scenario.tax_rate&.to_f,
          unit_price_snapshot: scenario.unit_price_snapshot&.to_f, price_changed: scenario.price_changed?,
          amount_financed: scenario.amount_financed&.to_f, monthly_payment: scenario.monthly_payment&.to_f,
          out_the_door: scenario.out_the_door&.to_f,
          unit_location_id: scenario.unit_location_id, unit_days_on_lot: scenario.unit_days_on_lot,
          is_cross_location: scenario.is_cross_location,
          quote_id: scenario.quote_id, created_by_id: scenario.created_by_id,
          created_at: scenario.created_at, updated_at: scenario.updated_at
        }
        if can_view_costs?
          base.merge!(front_gross: scenario.front_gross&.to_f, back_gross: scenario.back_gross&.to_f,
                      dealer_gross: scenario.dealer_gross&.to_f, unit_cost_snapshot: scenario.unit_cost_snapshot&.to_f)
          # Cost-viewers only: overwrite the price-only line_items with per-line cost + margin.
          base[:line_items] = Array(scenario.line_items).map do |li|
            li = li.symbolize_keys
            price = li[:price].to_f
            cost  = li[:cost].to_f
            qty   = (li[:quantity] || 1)
            { description: li[:description], price: price, quantity: qty,
              cost: cost, margin: ((price - cost) * qty).to_f }
          end
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
