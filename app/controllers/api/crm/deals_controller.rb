module Api
  module Crm
    class DealsController < ApplicationController
      before_action :set_company_scope
      before_action :set_deal, only: [:show, :update, :destroy, :move_stage, :tags, :add_tags, :remove_tag, :service_tickets]

      # GET /api/crm/deals
      def index
        return unless authorize_action!('deals', 'read')
        
        # STRICT TENANT ISOLATION: Only show deals from current company
        # RBAC: Location-tier users only see their assigned locations
        deals = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.deals
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.deals.where(location_id: location_ids)
            else
              @company.deals
            end
          end
        else
          @company.deals
        end
        
        # Apply location selector filter (if user selected a specific location)
        deals = deals.for_current_location
        
        # DEFAULT VIEW SCOPING: Sales reps see only their own deals unless explicitly requesting broader view
        # Admins and users with 'read_all' permission can expand to see all deals
        view_scope = params[:view] # 'my', 'team', 'all'
        
        unless current_user.effective_admin? || view_scope == 'all'
          # Default to "My Deals" for non-admin users
          deals = deals.where('deals.user_id = ? OR deals.primary_salesperson_id = ? OR deals.assigned_to = ?', 
                             current_user.id, current_user.id, current_user.email)
        end
        
        deals = deals.includes(:account, :contact, :territory, :user, :deal_products, :commission_plan)
                    .order(created_at: :desc)
        
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
        
        # Filter by status
        case params[:status]
        when 'open'
          deals = deals.open
        when 'won'
          deals = deals.won
        when 'lost'
          deals = deals.lost
        end
        
        # Count BEFORE pagination
        total_count = deals.count
        
        # Paginate
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min  # Cap at 200
        deals = deals.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          deals: deals.map { |d| deal_json(d) },
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
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
        
        # Apply strict location filter - only deals explicitly assigned to selected location
        if Current.location_filtered?
          deals = deals.where(location_id: Current.location_id)
        end
        
        deals = deals.includes(:account, :contact, :territory, :user, :deal_products)
                    .order(created_at: :desc)
        
        render json: deals.map { |d| deal_json(d) }
      end

      # GET /api/crm/deals/metrics
      def metrics
        return unless authorize_action!('deals', 'read')
        
        # STRICT TENANT ISOLATION: Only metrics for current company
        company_deals = @company.deals
        
        # Apply strict location filter - only deals explicitly assigned to selected location
        if Current.location_filtered?
          company_deals = company_deals.where(location_id: Current.location_id)
        end
        
        # DEFAULT VIEW SCOPING: Apply same scoping as index action
        view_scope = params[:view] # 'my', 'team', 'all'
        
        unless current_user.effective_admin? || view_scope == 'all'
          # Default to "My Deals" for non-admin users
          company_deals = company_deals.where('deals.user_id = ? OR deals.primary_salesperson_id = ? OR deals.assigned_to = ?', 
                                             current_user.id, current_user.id, current_user.email)
        end
        
        # Overall metrics
        total_value = company_deals.open.sum(:value)
        total_count = company_deals.open.count
        won_value = company_deals.won.sum(:value)
        won_count = company_deals.won.count
        lost_count = company_deals.lost.count
        
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
        
        # Apply strict location filter - only deals explicitly assigned to selected location
        if Current.location_filtered?
          forecast_deals = forecast_deals.where(location_id: Current.location_id)
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

      # POST /api/crm/deals
      # FIX: Improved error handling for deal creation
      def create
        return unless authorize_action!('deals', 'create')
        
        # STRICT TENANT ISOLATION: Create deal within current company
        deal = @company.deals.new(deal_params)
        
        # Auto-assign owner to current user if not specified
        deal.owner_id ||= current_user&.id
        
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
          :expected_close_date, :actual_close_date, :user_id, :assigned_to,
          :territory_id, :lead_source, :description, :notes,
          :win_reason, :loss_reason, :competitor,
          :customer_name, :source_id, :owner_id, :primary_salesperson_id, :delivery_date,
          # Economics fields
          :selling_price, :unit_cost, :pack_amount,
          :trade_allowance, :trade_payoff,
          :finance_reserve, :product_margin,
          :accessories_total, :doc_fee,
          :delivery_fee, :setup_fee, :skirting_fee,
          :deal_type, :vertical, :quantity,
          # Commission plan
          :commission_plan_id,
          # Deal Participants (for commission calculation)
          :sales_manager_id, :finance_manager_id, :desk_manager_id, :secondary_salesperson_id
          # NOTE: company_id is intentionally excluded - it should never change after creation
          # It's set via @company.deals.build and must remain immutable
        )
      end

      def current_user_id
        # This should be set by your authentication system
        # For now, returning nil - you'll need to implement this based on your auth
        current_user&.id
      end

      def deal_json(deal, detailed: false)
        # Check if user has permission to view cost details
        can_view_costs = current_user&.has_permission?('deals', 'read', scope: 'view_cost_details') || false
        
        base = {
          id: deal.id,
          name: deal.name,
          accountId: deal.account_id,
          accountName: deal.account&.name,
          contactId: deal.contact_id,
          contactName: deal.contact ? "#{deal.contact.first_name} #{deal.contact.last_name}".strip : nil,
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
          createdAt: deal.created_at&.iso8601,
          updatedAt: deal.updated_at&.iso8601,
          
          # Public economics fields (everyone can see)
          sellingPrice: deal.selling_price,
          tradeAllowance: deal.trade_allowance,
          tradePayoff: deal.trade_payoff,
          accessoriesTotal: deal.accessories_total,
          docFee: deal.doc_fee,
          deliveryFee: deal.delivery_fee,
          setupFee: deal.setup_fee,
          skirtingFee: deal.skirting_fee,
          dealType: deal.deal_type,
          vertical: deal.vertical,
          quantity: deal.quantity,
          
          # Commission plan info
          commissionPlanId: deal.commission_plan_id,
          commissionPlanName: deal.commission_plan&.name
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
          
          # Add primary vehicle from selling_price if present
          if deal.selling_price.present? && deal.selling_price > 0
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
