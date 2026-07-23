module Api
  module Crm
    class DealsController < ApplicationController
      before_action :set_company_scope
      before_action :set_deal, only: [:show, :update, :destroy, :move_stage, :tags, :add_tags, :remove_tag, :service_tickets, :max_advance]

      # GET /api/crm/deals
      def index
        return unless authorize_action!('deals', 'read')
        
        # Company deals narrowed by RBAC location access + the active location
        # filter (shared with #owners so the Owner dropdown matches the list).
        deals = deals_in_location_scope

        # DEFAULT VIEW SCOPING: Sales reps see only their own deals unless explicitly requesting broader view
        # Admins and users with 'read_all' permission can expand to see all deals
        view_scope = params[:view] # 'my', 'team', 'all'
        
        unless current_user.effective_admin? || view_scope == 'all'
          # Default to "My Deals" for non-admin users
          deals = deals.where('deals.user_id = ? OR deals.primary_salesperson_id = ? OR deals.assigned_to = ?', 
                             current_user.id, current_user.id, current_user.email)
        end
        
        deals = deals.includes(:account, :contact, :co_applicant_contact, :territory, :user, :location, :deal_products, :commission_plan)
        # sort_by=name gives pickers a stable alphabetical list; default stays newest-first
        deals = if params[:sort_by] == 'name'
                  deals.order(Arel.sql('LOWER(deals.name) ASC'), :id)
                else
                  deals.order(created_at: :desc)
                end

        # Filter by account if provided (support both account_id and customer_id for backward compatibility)
        if params[:account_id].present?
          deals = deals.where(account_id: params[:account_id])
        elsif params[:customer_id].present?
          # customer_id can refer to either account_id or contact_id
          deals = deals.where('account_id = ? OR contact_id = ?', params[:customer_id], params[:customer_id])
        end
        
        # Filter by contact if provided
        deals = deals.where(contact_id: params[:contact_id]) if params[:contact_id].present?
        
        # Filter by stage if provided
        deals = deals.where(stage: params[:stage]) if params[:stage].present?
        
        # Filter by territory if provided
        deals = deals.where(territory_id: params[:territory_id]) if params[:territory_id].present?
        
        # Filter by owner if provided
        deals = deals.where(user_id: params[:user_id]) if params[:user_id].present?

        # Filter by deal owner (owner_id), matching the frontend's Owner filter.
        # 'null' = unassigned.
        if params[:owner_id].present?
          deals = params[:owner_id] == 'null' ? deals.where(owner_id: nil) : deals.where(owner_id: params[:owner_id])
        end

        # Filter by status
        case params[:status]
        when 'open'
          deals = deals.open
        when 'won'
          deals = deals.won(@company)
        when 'lost'
          deals = deals.lost(@company)
        end

        # Apply search filter
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          deals = deals.where(
            "deals.name ILIKE ? OR deals.customer_name ILIKE ? OR deals.description ILIKE ?",
            search_term, search_term, search_term
          )
        end
        
        # Count BEFORE pagination
        total_count = deals.count
        
        # Paginate
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min  # Cap at 200
        deals = deals.offset((page - 1) * per_page).limit(per_page)

        # Batch-load the most recent polymorphic Note per deal so the list/cards/
        # kanban views can show a Notes preview with hover details — without N+1
        # queries. Postgres DISTINCT ON keeps just the first row per entity_id;
        # the inner ORDER BY makes "first" mean "most recent".
        page_ids = deals.map(&:id).map(&:to_s)
        last_notes_by_deal = if page_ids.any?
          Note.where(entity_type: 'deal', entity_id: page_ids)
              .order(Arel.sql('entity_id, created_at DESC'))
              .select('DISTINCT ON (entity_id) entity_id, content, created_at, created_by_name')
              .each_with_object({}) { |n, acc| acc[n.entity_id.to_i] = n }
        else
          {}
        end

        render json: {
          deals: deals.map { |d|
            n = last_notes_by_deal[d.id]
            deal_json(d).merge(
              lastNote: n ? { content: n.content, createdAt: n.created_at, createdByName: n.created_by_name } : nil
            )
          },
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      # GET /api/crm/deals/owners
      # Distinct deal owners within the caller's scope, so the Owner filter only
      # lists users who actually own deals (not every company user). Honors the
      # same RBAC + location scoping as the list, so the options match what's
      # visible. Includes a hasUnassigned flag for the "Unassigned" option.
      def owners
        return unless authorize_action!('deals', 'read')

        deals = deals_in_location_scope

        owner_ids      = deals.where.not(owner_id: nil).distinct.pluck(:owner_id)
        has_unassigned = deals.where(owner_id: nil).exists?

        owners = @company.users.where(id: owner_ids).map do |u|
          { id: u.id, name: u.name, email: u.email }
        end.sort_by { |o| o[:name].to_s.downcase }

        render json: { owners: owners, hasUnassigned: has_unassigned }
      end

      # GET /api/crm/deals/by_stage
      def by_stage
        return unless authorize_action!('deals', 'read')
        
        stage = params[:stage]
        if stage.blank?
          render json: { error: 'Stage parameter is required' }, status: :bad_request
          return
        end
        
        # STRICT TENANT ISOLATION: Only show deals from current company
        deals = @company.deals.where(stage: stage)

        # Location filter (param overrides header; legacy = strict header narrowing)
        deals = filter_deals_by_location(deals) do |scope|
          Current.location_filtered? ? scope.where(location_id: Current.location_id) : scope
        end

        deals = deals.includes(:account, :contact, :co_applicant_contact, :territory, :user, :location, :deal_products)
                    .order(created_at: :desc)
        
        render json: deals.map { |d| deal_json(d) }
      end

      # GET /api/crm/deals/metrics
      def metrics
        return unless authorize_action!('deals', 'read')
        
        # STRICT TENANT ISOLATION: Only metrics for current company
        company_deals = @company.deals

        # Location filter (param overrides header; legacy = strict header narrowing)
        company_deals = filter_deals_by_location(company_deals) do |scope|
          Current.location_filtered? ? scope.where(location_id: Current.location_id) : scope
        end

        # DEFAULT VIEW SCOPING: Apply same scoping as index action
        view_scope = params[:view] # 'my', 'team', 'all'
        
        unless current_user.effective_admin? || view_scope == 'all'
          # Default to "My Deals" for non-admin users
          company_deals = company_deals.where('deals.user_id = ? OR deals.primary_salesperson_id = ? OR deals.assigned_to = ?',
                                             current_user.id, current_user.id, current_user.email)
        end

        # Filter by deal owner (owner_id), matching the index/list Owner filter.
        # 'null' = unassigned.
        if params[:owner_id].present?
          company_deals = params[:owner_id] == 'null' ? company_deals.where(owner_id: nil) : company_deals.where(owner_id: params[:owner_id])
        end

        # Overall metrics
        total_value = company_deals.open.sum(:value)
        total_count = company_deals.open.count
        won_value = company_deals.won(@company).sum(:value)
        won_count = company_deals.won(@company).count
        lost_count = company_deals.lost(@company).count
        
        # Win rate
        closed_count = won_count + lost_count
        win_rate = closed_count > 0 ? (won_count.to_f / closed_count * 100).round(2) : 0
        
        # Average deal size
        avg_deal_value = total_count > 0 ? (total_value / total_count).round(2) : 0
        
        # By stage - using lowercase normalized stages
        by_stage = company_deals.open.group(:stage).count
        value_by_stage = company_deals.open.group(:stage).sum(:value)
        
        # Recent activity
        recent_created = company_deals.where('created_at >= ?', 30.days.ago).count
        recent_won = company_deals.where('won_at >= ?', 30.days.ago).count
        recent_lost = company_deals.where('lost_at >= ?', 30.days.ago).count
        
        render json: {
          total: {
            value: total_value,
            count: total_count,
            avgValue: avg_deal_value
          },
          won: {
            value: won_value,
            count: won_count
          },
          lost: {
            count: lost_count
          },
          winRate: win_rate,
          byStage: by_stage.transform_keys(&:to_s),
          valueByStage: value_by_stage.transform_keys(&:to_s),
          recent: {
            created: recent_created,
            won: recent_won,
            lost: recent_lost
          }
        }
      end

      # GET /api/crm/deals/forecast
      def forecast
        return unless authorize_action!('deals', 'read')
        
        # STRICT TENANT ISOLATION: Only forecast for current company
        # Calculate forecast by territory and time period
        period = params[:period] || 'month' # month, quarter, year
        
        date_field = case period
        when 'quarter'
          '3 months'
        when 'year'
          '12 months'
        else
          '1 month'
        end
        
        forecast_deals = @company.deals
                            .where('expected_close_date <= ?', date_field.to_s.split.first.to_i.send(date_field.split.last).from_now)
                            .where(stage: ['proposal', 'negotiation', 'closing'])
        
        # Location filter (param overrides header; legacy = strict header narrowing)
        forecast_deals = filter_deals_by_location(forecast_deals) do |scope|
          Current.location_filtered? ? scope.where(location_id: Current.location_id) : scope
        end

        total_forecast = forecast_deals.sum(:value)
        weighted_forecast = forecast_deals.sum('value * probability / 100')
        
        by_territory = {}
        # STRICT TENANT ISOLATION: Only show territories for current company
        @company.territories.each do |territory|
          territory_deals = forecast_deals.where(territory_id: territory.id)
          by_territory[territory.id] = {
            name: territory.name,
            totalValue: territory_deals.sum(:value),
            weightedValue: territory_deals.sum('value * probability / 100'),
            count: territory_deals.count
          }
        end
        
        render json: {
          period: period,
          totalForecast: total_forecast,
          weightedForecast: weighted_forecast,
          byTerritory: by_territory
        }
      end

      # GET /api/crm/deals/:id
      def show
        return unless authorize_action!('deals', 'read')

        render json: deal_json(@deal, detailed: true)
      end

      # GET /api/crm/deals/:id/max_advance
      # Lender Max Advance for this deal's vehicle (Phase 4a surfacing), with a status
      # classifying the deal's home line-item price against the caps. Cost-derived, so it
      # additionally requires deals:read:view_cost_details (mirrors deal_json cost gating).
      def max_advance
        return unless authorize_action!('deals', 'read')

        unless current_user&.has_permission?('deals', 'read', scope: 'view_cost_details')
          return render json: { error: 'Forbidden - cost details permission required',
                                required_permission: 'deals:read:view_cost_details' }, status: :forbidden
        end

        vehicle = @deal.vehicle
        # Lender: explicit ?lender_id= override (live preview from the deal's lender picker)
        # falls back to the deal's saved lender.
        lender =
          if params[:lender_id].present?
            @company.lenders.active.find_by(id: params[:lender_id]) || @deal.lender
          else
            @deal.lender
          end

        # LIVE PREVIEW: when the client passes the current (possibly unsaved) line items, use
        # them — so adding a home + packages mid-edit immediately resolves allowances and
        # recomputes caps WITHOUT requiring a save. Otherwise fall back to the deal's saved
        # deal_products. Both go through the SAME resolver so behavior is identical.
        if params[:items].present?
          home_price, deal_items = items_from_params(params[:items])
        else
          home_price = nil
          deal_items = deal_addon_items_for(@deal)
        end

        # Home line-item price is the BASE of the financed package. From the passed items when
        # previewing; otherwise the LIVE home line item price (what the rep currently sees),
        # falling back to selling_price, then all-lines total, for legacy deals.
        if home_price.nil? || home_price.to_f <= 0
          home_price = @deal.home_line_item_price
          home_price = @deal.selling_price if home_price.nil? || home_price.to_f <= 0
          home_price = @deal.line_items_price if home_price.nil? || home_price.to_f <= 0
        end
        home_price = home_price.to_f

        # Dealer-installed item allowances on the deal drive the CONFIGURED max advance; base
        # is computed alongside. resolve_items returns BOTH the calculator adds and a display
        # list flagging each line allowance-backed vs dealer-add-on.
        resolved = MaxAdvanceSurfacing.resolve_items(company: @company, items: deal_items)
        adds = resolved[:adds]

        # COMPARED (financed) PRICE = home price + the SELLING PRICES of the qualified
        # (allowance-backed) add-ons. That's the apples-to-apples figure against the caps,
        # which themselves are home + those add-ons' allowances. Non-qualified add-ons
        # (no lender allowance) are EXCLUDED — they sit outside the financed portion (shown
        # in the worksheet's "not advanced by lender" group). The gap between a qualified
        # add-on's selling price and its allowance is the unfinanceable overage, which the
        # GREEN/YELLOW/RED flag surfaces.
        qualified_addons_price = resolved[:line_items].sum { |li| li[:allowance_backed] ? li[:price].to_f * (li[:qty].to_i.positive? ? li[:qty].to_i : 1) : 0.0 }
        price = (home_price + qualified_addons_price).round(2)

        result = MaxAdvanceSurfacing.evaluate(
          vehicle: vehicle, lender: lender, deal: @deal, price: price, adds: adds
        )

        render json: {
          dealId: @deal.id,
          vehicleId: vehicle&.id,
          vehicleName: vehicle&.display_name,
          lenderId: lender&.id,
          lenderName: lender&.name,
          comparedPrice: price,                 # home + qualified add-on selling prices (financed package)
          homePrice: home_price,                # home line only
          qualifiedAddonsPrice: qualified_addons_price.round(2),
          standardMsp: result[:standard_msp],   # CONFIGURED (base + selected allowances)
          maximumMsp: result[:maximum_msp],
          baseStandardMsp: result[:base_standard_msp],  # bare home, no adds
          baseMaximumMsp: result[:base_maximum_msp],
          addsCount: adds.size,
          status: result[:status],            # within_standard | within_maximum | over_maximum | null
          reason: result[:reason],            # null, or why MSP couldn't be computed
          flag: result[:reason] ? MaxAdvanceSurfacing.flag_for(result[:reason]) : nil,
          breakdown: result[:breakdown],
          lineItems: resolved[:line_items],   # deal's add-ons, allowance-flagged (for the worksheet)
          # Lenders the rep can pick from the deal's Max Advance bar (so they don't have to
          # leave the deal to set one). hasSchedule flags which have a markup config.
          availableLenders: @company.lenders.active.by_name.map { |l| { id: l.id, name: l.name, hasSchedule: l.markup_config.present? } }
        }
      end

      # POST /api/crm/deals
      # FIX: Improved error handling for deal creation
      def create
        return unless authorize_action!('deals', 'create')
        
        # STRICT TENANT ISOLATION: Create deal within current company
        deal = @company.deals.new(deal_params)
        
        # Auto-assign owner to current user if not specified
        deal.owner_id ||= current_user&.id
        deal.user_id ||= current_user&.id

        # Copy addresses from contact or account if not already set
        if deal.billing_street.blank?
          if deal.contact_id.present?
            contact = @company.contacts.find_by(id: deal.contact_id)
            PipelineCopyService.contact_to_deal(contact, deal) if contact
          elsif deal.account_id.present?
            account = @company.accounts.find_by(id: deal.account_id)
            if account
              deal.billing_street  ||= account.billing_street
              deal.billing_city    ||= account.billing_city
              deal.billing_state   ||= account.billing_state
              deal.billing_zip     ||= account.billing_postal_code
              deal.billing_country ||= account.billing_country
              deal.delivery_street  ||= account.shipping_street
              deal.delivery_city    ||= account.shipping_city
              deal.delivery_state   ||= account.shipping_state
              deal.delivery_zip     ||= account.shipping_postal_code
              deal.delivery_country ||= account.shipping_country
            end
          end
        end
        
        # Auto-assign location from selector (if user selected a specific location)
        deal.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if deal.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          deal.location_id ||= location_ids.first if location_ids.any?
        end
        
        if deal.save
          # FIX: Safely create stage history with error handling
          begin
            deal.deal_stage_histories.create(
              stage: deal.stage,
              changed_by_id: current_user_id,
              notes: 'Deal created'
            )
          rescue => e
            # Log the error but don't fail the request
            Rails.logger.error "Failed to create stage history: #{e.message}"
          end
          
          render json: deal_json(deal, detailed: true), status: :created
        else
          render json: { errors: deal.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        # FIX: Catch any unexpected errors and return meaningful message
        Rails.logger.error "Deal creation failed: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: "Failed to create deal: #{e.message}" }, status: :internal_server_error
      end

      # PATCH/PUT /api/crm/deals/:id
      def update
        return unless authorize_action!('deals', 'update')
        
        old_stage = @deal.stage

        # Merge custom_field_values rather than replace (preserves other custom fields)
        if params[:deal][:custom_field_values].present?
          existing = @deal.custom_field_values || {}
          merged = existing.merge(params[:deal][:custom_field_values].to_unsafe_h)
          params[:deal][:custom_field_values] = merged
        end
        
        if @deal.update(deal_params)
          # Track stage change
          if old_stage != @deal.stage
            begin
              @deal.deal_stage_histories.create(
                stage: @deal.stage,
                previous_stage: old_stage,
                changed_by_id: current_user_id,
                notes: params[:stage_change_notes]
              )
            rescue => e
              Rails.logger.error "Failed to create stage history: #{e.message}"
            end

            # Auto-set actual_close_date when deal is won
            if @deal.stage_is_won? && @deal.actual_close_date.blank?
              @deal.update_column(:actual_close_date, Date.today)
            end
          end

          render json: deal_json(@deal, detailed: true)
        else
          render json: { errors: @deal.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/crm/deals/:id/move_stage
      def move_stage
        return unless authorize_action!('deals', 'update')
        
        new_stage = params[:stage]
        notes = params[:notes]
        
        if new_stage.blank?
          render json: { error: 'Stage is required' }, status: :bad_request
          return
        end
        
        old_stage = @deal.stage
        
        if @deal.update(stage: new_stage)
          # Create stage history
          begin
            @deal.deal_stage_histories.create(
              stage: new_stage,
              previous_stage: old_stage,
              changed_by_id: current_user_id,
              notes: notes
            )
          rescue => e
            Rails.logger.error "Failed to create stage history: #{e.message}"
          end

          # Auto-set actual_close_date when deal is won
          if @deal.stage_is_won? && @deal.actual_close_date.blank?
            @deal.update_column(:actual_close_date, Date.today)
          end
          
          render json: deal_json(@deal, detailed: true)
        else
          render json: { errors: @deal.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/crm/deals/:id/tags
      def tags
        return unless authorize_action!('deals', 'read')
        
        # Get tags through the association
        tags = @deal.tags.map do |tag|
          {
            id: tag.id,
            name: tag.name,
            description: tag.description,
            color: tag.color,
            category: tag.category,
            type: tag.try(:tag_type),
            isSystem: tag.try(:is_system),
            isActive: tag.try(:is_active),
            usageCount: tag.usage_count,
            createdBy: tag.try(:created_by),
            createdAt: tag.created_at,
            updatedAt: tag.updated_at
          }.compact
        end
        
        render json: tags
      end

      # POST /api/crm/deals/:id/tags
      def add_tags
        return unless authorize_action!('deals', 'update')
        
        tag_names = params[:tags] || []
        tag_names = tag_names.split(',') if tag_names.is_a?(String)
        
        tag_names.each do |tag_name|
          # Find or create tag within current company scope
          tag = @company.tags.find_or_create_by!(name: tag_name.strip) do |new_tag|
            new_tag.color = '#6B7280'
            new_tag.is_active = true
            new_tag.created_by = current_user&.id&.to_s || 'system'
          end
          
          # Create tag assignment using polymorphic association
          TagAssignment.find_or_create_by!(
            tag: tag,
            entity_type: 'Deal',
            entity_id: @deal.id
          ) do |assignment|
            assignment.company_id = @company.id
            assignment.assigned_by = current_user&.id&.to_s || 'system'
            assignment.assigned_at = Time.current
          end
        end
        
        # Reload tags association to get updated list
        @deal.reload
        render json: deal_json(@deal, detailed: true)
      end

      # DELETE /api/crm/deals/:id/tags/:tag_name
      def remove_tag
        return unless authorize_action!('deals', 'update')
        
        # Find tag within company scope
        tag = @company.tags.find_by(name: params[:tag_name])
        
        if tag
          # Remove tag assignment using polymorphic association
          TagAssignment.where(
            tag: tag,
            entity_type: 'Deal',
            entity_id: @deal.id
          ).destroy_all
        end
        
        # Reload tags association to get updated list
        @deal.reload
        render json: deal_json(@deal, detailed: true)
      end

      # DELETE /api/crm/deals/:id
      def destroy
        return unless authorize_action!('deals', 'delete')
        
        @deal.destroy
        head :no_content
      end

      # GET /api/crm/deals/:id/service_tickets
      def service_tickets
        return unless authorize_action!('service', 'read')
        
        # STRICT TENANT ISOLATION: Only show service tickets from the same company
        tickets = @deal.service_tickets.includes(:account, :contact, :vehicle)
        
        # Apply location filter if needed
        if Current.location_filtered?
          tickets = tickets.where(location_id: Current.location_id)
        end
        
        tickets = tickets.order(created_at: :desc)
        
        render json: {
          data: tickets.map { |ticket| serialize_service_ticket(ticket) }
        }
      end

      private

      # Company deals narrowed by RBAC location access + the active location
      # filter, WITHOUT the my/all owner scoping. Shared by #index and #owners
      # so the Owner dropdown only lists owners of deals the caller can see.
      def deals_in_location_scope
        base = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          location_ids.any? ? @company.deals.where(location_id: location_ids) : @company.deals
        else
          @company.deals
        end

        filter_deals_by_location(base) { |scope| scope.for_current_location }
      end

      # Shared location filtering for the deals list and its tile/metric actions
      # so they always agree. An explicit location_id param overrides the
      # X-Location-ID selector header:
      #   'all'  => no header narrowing (every location already in scope)
      #   <id>   => that single location, access-checked against RBAC + company
      #   absent => the action's legacy header behavior, supplied as a block
      def filter_deals_by_location(scope)
        location_param = params[:location_id].to_s
        return scope if location_param == 'all'

        if location_param.present?
          loc_id  = location_param.to_i
          allowed = current_user.effective_admin? ||
                    !current_user.uses_rbac? ||
                    permission_service.accessible_location_ids.include?(loc_id)
          return (allowed && @company.locations.exists?(id: loc_id)) ? scope.where(location_id: loc_id) : scope.none
        end

        block_given? ? yield(scope) : scope
      end

      def serialize_service_ticket(ticket)
        {
          id: ticket.id,
          ticketNumber: ticket.ticket_number,
          title: ticket.title,
          description: ticket.description,
          status: ticket.status,
          priority: ticket.priority,
          assignedTo: ticket.assigned_to,
          scheduledDate: ticket.scheduled_date&.iso8601,
          accountId: ticket.account_id,
          accountName: ticket.account&.name,
          contactId: ticket.contact_id,
          contactName: ticket.contact ? "#{ticket.contact.first_name} #{ticket.contact.last_name}".strip : nil,
          vehicleId: ticket.vehicle_id,
          vehicleName: ticket.vehicle&.display_name,
          dealId: ticket.deal_id,
          createdAt: ticket.created_at&.iso8601,
          updatedAt: ticket.updated_at&.iso8601
        }
      end

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [DealsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [DealsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [DealsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [DealsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_deal
        # STRICT TENANT ISOLATION: Only access deals in same company
        # RBAC: Location-tier users only access their assigned locations
        @deal = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.deals.where(location_id: location_ids).find(params[:id])
          else
            @company.deals.find(params[:id])
          end
        else
          @company.deals.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found or access denied' }, status: :not_found
        return
      end

      def deal_params
        params.require(:deal).permit(
          :name, :account_id, :contact_id, :vehicle_id, :value, :stage, :probability,
          # Co-applicant link. Settable after conversion via the Applicants card
          # picker; Deal#co_applicant_contact_is_valid enforces same-company,
          # same-account, and not-the-primary. Blank clears it.
          :co_applicant_contact_id,
          :expected_close_date, :actual_close_date, :user_id, :assigned_to,
          :territory_id, :lead_source, :description, :notes,
          :win_reason, :loss_reason, :competitor,
          :customer_name, :source_id, :owner_id, :primary_salesperson_id, :delivery_date,
          # Economics fields
          # NOTE: selling_price and unit_cost are DERIVED, not input (Phase 2B).
          # selling_price mirrors the home line item's price (Deal#mirror_selling_price_from_home_line);
          # unit_cost is a passive mirror of the home cost (Deal#sync_vehicle_pricing).
          # Permitting them would let the client overwrite the source of truth.
          :pack_amount,
          :trade_allowance, :trade_payoff,
          :finance_reserve, :product_margin,
          :accessories_total, :doc_fee,
          :delivery_fee, :setup_fee, :skirting_fee,
          # Deposit (a.k.a. down payment): the up-front cash the buyer puts
          # toward the purchase. Reports read this column ("Deposit" in
          # Sales GP and Inventory reports).
          :down_payment, :down_payment_due_date,
          # Lender: lender_id references the managed list and denormalizes to lender_name
          # (see Deal#denormalize_lender_name); lender_name still accepted as a free string.
          :lender_id, :lender_name, :payment_type,
          :deal_type, :vertical, :quantity,
          # Commission plan
          :commission_plan_id,
          # Deal Participants (for commission calculation)
          :sales_manager_id, :finance_manager_id, :desk_manager_id, :secondary_salesperson_id,
          # Addresses (billing + delivery)
          :billing_street, :billing_city, :billing_state, :billing_zip, :billing_country,
          :delivery_street, :delivery_city, :delivery_state, :delivery_zip, :delivery_country,
          # Custom fields (JSONB column - merged in update action, never replaced)
          custom_field_values: {}
          # NOTE: company_id is intentionally excluded - it should never change after creation
          # It's set via @company.deals.build and must remain immutable
        )
      end

      def current_user_id
        # This should be set by your authentication system
        # For now, returning nil - you'll need to implement this based on your auth
        current_user&.id
      end

      # Build the raw add-on item list from this deal's line items, for MaxAdvanceSurfacing
      # to resolve (-> calculator adds + display list). Both the deal's Max Advance caps and
      # the deal worksheet use the SAME resolution as the inventory worksheet, so they stay
      # consistent.
      #
      # A deal's add-ons can arrive two ways:
      #   1. Standard-item lines tagged `allowance:<id>` in notes (exact id match)
      #   2. Lines applied from an inventory PACKAGE (source:package) whose name matches a
      #      CompanyAllowanceDefault (e.g. "Air Conditioner", "Steps & Decks") — name match
      # resolve_items tries the id first, then the name; non-allowance items (Porch, custom)
      # are returned in the display list but excluded from adds (flag-don't-guess).
      #
      # The home line (notes include 'category:home' / 'source:home') is excluded — it's the
      # base, not an add-on.
      def deal_addon_items_for(deal)
        deal.deal_products.filter_map do |dp|
          notes = dp.notes.to_s
          next if notes.include?('category:home') || notes.include?('source:home')

          allowance_id = notes[/allowance:(\d+)/, 1]
          {
            name: dp.product_name.to_s,
            price: dp.unit_price.to_f,
            qty: dp.quantity.to_i.positive? ? dp.quantity.to_i : 1,
            allowance_default_id: allowance_id.presence&.to_i
          }
        end
      end

      # Parse client-sent CURRENT line items (live, possibly unsaved) for a Max Advance preview.
      # Returns [home_price, addon_items] where addon_items match the resolve_items shape. The
      # home line (category:'home') becomes the base price; every other line is an add-on
      # candidate (resolve_items decides which are allowance-backed). This lets the deal form
      # reflect a just-added home + its packages WITHOUT a save. Read-only: nothing is written.
      #
      # Each item: { name:, price:, qty:, category:, allowanceDefaultId? }.
      def items_from_params(items)
        list = items.respond_to?(:values) && !items.is_a?(Array) ? items.values : Array(items)
        home_price = 0.0
        addons = []
        list.each do |raw|
          it = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
          it = it.with_indifferent_access if it.respond_to?(:with_indifferent_access)
          name  = it[:name].to_s
          price = it[:price].to_f
          qty   = it[:qty].to_i.positive? ? it[:qty].to_i : 1
          cat   = it[:category].to_s
          if cat == 'home'
            home_price += price * qty
            next
          end
          addons << {
            name: name,
            price: price,
            qty: qty,
            allowance_default_id: it[:allowanceDefaultId].presence&.to_i
          }
        end
        [home_price, addons]
      end

      def deal_json(deal, detailed: false)
        # Check if user has permission to view cost details
        can_view_costs = current_user&.has_permission?('deals', 'read', scope: 'view_cost_details') || false
        
        base = {
          id: deal.id,
          dealNumber: deal.deal_number,
          name: deal.name,
          accountId: deal.account_id,
          accountName: deal.account&.name,
          contactId: deal.contact_id,
          contactName: deal.contact ? "#{deal.contact.first_name} #{deal.contact.last_name}".strip : nil,
          contactEmail: deal.contact&.email,
          contactPhone: deal.contact&.phone,
          # Co-applicant / co-borrower. Derived from the linked Contact rather
          # than stored on the deal, so edits to the contact show here with no
          # sync step. contactId is included so the UI can deep-link into that
          # contact's Communication tab.
          coApplicantContactId: deal.co_applicant_contact_id,
          coApplicantName: deal.co_applicant_contact ?
            "#{deal.co_applicant_contact.first_name} #{deal.co_applicant_contact.last_name}".strip : nil,
          coApplicantEmail: deal.co_applicant_contact&.email,
          coApplicantPhone: deal.co_applicant_contact&.phone,
          vehicleId: deal.vehicle_id,
          vehicleName: deal.vehicle&.display_name,
          vehicleInventoryId: deal.vehicle&.inventory_id,
          customerName: deal.customer_display_name,
          value: deal.calculated_value,  # Calculated: selling_price + deal_products total
          stage: deal.stage,
          probability: deal.probability,
          expectedCloseDate: deal.expected_close_date&.iso8601,
          actualCloseDate: deal.actual_close_date&.iso8601,
          deliveryDate: deal.delivery_date&.iso8601,
          userId: deal.user_id,
          userName: deal.user&.name,
          ownerId: deal.owner_id,
          owner: deal.owner ? { id: deal.owner.id, name: deal.owner.name, email: deal.owner.email } : nil,
          primarySalespersonId: deal.primary_salesperson_id,
          
          # Deal Participants (for commission calculation)
          salesManagerId: deal.sales_manager_id,
          financeManagerId: deal.finance_manager_id,
          deskManagerId: deal.desk_manager_id,
          secondarySalespersonId: deal.secondary_salesperson_id,
          
          assignedTo: deal.assigned_to,
          territoryId: deal.territory_id,
          territoryName: deal.territory&.name,
          locationId: deal.location_id,
          locationName: deal.location&.name,
          leadSource: deal.lead_source,
          sourceId: deal.source_id,
          sourceName: deal.source&.name,
          description: deal.description,
          notes: deal.notes,
          wonAt: deal.won_at&.iso8601,
          lostAt: deal.lost_at&.iso8601,
          winReason: deal.win_reason,
          lossReason: deal.loss_reason,
          competitor: deal.competitor,
          customFieldValues: deal.custom_field_values || {},
          createdAt: deal.created_at&.iso8601,
          updatedAt: deal.updated_at&.iso8601,
          # Most recent activity timestamp on the deal — bumped by the
          # DealActivity callback whenever a call/email/task/etc. is logged,
          # and by Note when a quick-log note is added. Powers the Last
          # Activity column on the deals list & kanban.
          lastActivityAt: deal.last_activity_at&.iso8601,
          
          # Public economics fields (everyone can see)
          sellingPrice: deal.selling_price,
          tradeAllowance: deal.trade_allowance,
          tradePayoff: deal.trade_payoff,
          accessoriesTotal: deal.accessories_total,
          docFee: deal.doc_fee,
          deliveryFee: deal.delivery_fee,
          setupFee: deal.setup_fee,
          skirtingFee: deal.skirting_fee,
          # Deposit (persisted as `down_payment`; UI labels it "Deposit").
          # Reports also read `down_payment` — this is the single source of truth.
          downPayment: deal.down_payment,
          downPaymentDueDate: deal.down_payment_due_date&.iso8601,
          dealType: deal.deal_type,
          vertical: deal.vertical,
          quantity: deal.quantity,
          
          # Addresses
          billingStreet: deal.billing_street,
          billingCity: deal.billing_city,
          billingState: deal.billing_state,
          billingZip: deal.billing_zip,
          billingCountry: deal.billing_country,
          deliveryStreet: deal.delivery_street,
          deliveryCity: deal.delivery_city,
          deliveryState: deal.delivery_state,
          deliveryZip: deal.delivery_zip,
          deliveryCountry: deal.delivery_country,
          
          # Commission plan info
          commissionPlanId: deal.commission_plan_id,
          commissionPlanName: deal.commission_plan&.name,

          # Lender (managed list). Returned so the deal form / Max Advance bar re-hydrate the
          # saved lender on reload — without these the picker shows blank even though lender_id
          # is persisted.
          lenderId: deal.lender_id,
          lenderName: deal.lender_name,
          paymentType: deal.payment_type,

          # GL / approval status (public flags — not cost data). gl_posted is set when the
          # deal is approved + posted to the GL from the Deal Approvals queue; the FE shows an
          # "Approved by Mgr" badge with the timestamp. commission_posted mirrors the second
          # accounting gate.
          glPosted: deal.gl_posted || false,
          glPostedAt: deal.gl_posted_at&.iso8601,
          commissionPosted: deal.commission_posted || false,
          commissionPostedAt: deal.commission_posted_at&.iso8601
        }
        
        # Private economics fields (finance only)
        if can_view_costs
          base.merge!({
            unitCost: deal.unit_cost,
            packAmount: deal.pack_amount,
            financeReserve: deal.finance_reserve,
            productMargin: deal.product_margin,
            
            # Calculated grosses (also finance only)
            frontGross: deal.front_gross,
            backGross: deal.back_gross,
            totalGross: deal.total_gross,
            commissionableFrontGross: deal.commissionable_front_gross,
            effectivePackAmount: deal.effective_pack_amount
          })
        end
        
        if detailed
          products_array = []
          
          # LEGACY FALLBACK ONLY (Phase 2B): the home is a real line item now. Inject
          # the synthetic 'primary-vehicle' line solely for genuinely legacy deals that
          # have NO line items AND NO home line — so their home price still renders.
          # Deals with a home line list it as a real deal_product below; no injection.
          if deal.deal_products.empty? && !deal.has_home_line_item? &&
             deal.selling_price.present? && deal.selling_price > 0
            products_array << {
              id: 'primary-vehicle',
              productId: deal.vehicle_id,
              productName: deal.vehicle_display_name || 'Primary Vehicle',
              productSku: deal.vehicle&.inventory_id,
              quantity: deal.quantity || 1,
              unitPrice: deal.selling_price,
              discount: 0,
              tax: 0,
              total: deal.selling_price,
              notes: 'Primary vehicle from deal'
            }
          end
          
          # Add all deal_products
          products_array.concat(deal.deal_products.map { |dp| deal_product_json(dp) })
          
          base.merge!(
            products: products_array,
            stageHistory: deal.deal_stage_histories.order(created_at: :desc).limit(10).map { |sh| stage_history_json(sh) }
          )
        end
        
        base
      end

      def deal_product_json(dp)
        {
          id: dp.id,
          productId: dp.product_id,
          productName: dp.product_name,
          productSku: dp.product_sku,
          quantity: dp.quantity,
          unitPrice: dp.unit_price,
          discount: dp.discount,
          discountType: dp.discount_type,
          tax: dp.tax,
          total: dp.total,
          notes: dp.notes
        }
      end

      def stage_history_json(sh)
        {
          id: sh.id,
          stage: sh.stage,
          previousStage: sh.previous_stage,
          changedById: sh.changed_by_id,
          changedByName: sh.changed_by&.name,
          duration: sh.duration,
          notes: sh.notes,
          createdAt: sh.created_at&.iso8601
        }
      end
    end
  end
end
