module Api
  module Crm
    class DealsController < ApplicationController
      before_action :set_company_scope
      before_action :set_deal, only: [:show, :update, :destroy, :move_stage]

      # GET /api/crm/deals
      def index
        # STRICT TENANT ISOLATION: Only show deals from current company
        deals = @company.deals
                    .includes(:account, :contact, :territory, :user, :deal_products)
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
        
        render json: { deals: deals.map { |d| deal_json(d) } }
      end

      # GET /api/crm/deals/by_stage
      def by_stage
        stage = params[:stage]
        if stage.blank?
          render json: { error: 'Stage parameter is required' }, status: :bad_request
          return
        end
        
        # STRICT TENANT ISOLATION: Only show deals from current company
        deals = @company.deals
                    .where(stage: stage)
                    .includes(:account, :contact, :territory, :user, :deal_products)
                    .order(created_at: :desc)
        
        render json: deals.map { |d| deal_json(d) }
      end

      # GET /api/crm/deals/metrics
      def metrics
        # STRICT TENANT ISOLATION: Only metrics for current company
        company_deals = @company.deals
        
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
        
        total_forecast = forecast_deals.sum(:value)
        weighted_forecast = forecast_deals.sum('value * probability / 100')
        
        by_territory = {}
        Territory.all.each do |territory|
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
        render json: deal_json(@deal, detailed: true)
      end

      # POST /api/crm/deals
      # FIX: Improved error handling for deal creation
      def create
        # STRICT TENANT ISOLATION: Create deal within current company
        deal = @company.deals.new(deal_params)
        # Don't set user_id if there's no real current_user
        # deal.user_id ||= current_user&.id
        
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

      # DELETE /api/crm/deals/:id
      def destroy
        @deal.destroy
        head :no_content
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [DealsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        unless current_user.company_id.present?
          Rails.logger.error "🚫 [DealsController] User #{current_user.id} has no company_id"
          render json: { error: 'No company assigned' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: current_user.company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [DealsController] Company #{current_user.company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [DealsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_deal
        # STRICT TENANT ISOLATION: Only access deals in same company
        @deal = @company.deals.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found or access denied' }, status: :not_found
      end

      def deal_params
        params.require(:deal).permit(
          :name, :account_id, :contact_id, :vehicle_id, :value, :stage, :probability,
          :expected_close_date, :actual_close_date, :user_id, :assigned_to,
          :territory_id, :lead_source, :description, :notes,
          :win_reason, :loss_reason, :competitor,
          :customer_name, :source_id, :company_id
        )
      end

      def current_user_id
        # This should be set by your authentication system
        # For now, returning nil - you'll need to implement this based on your auth
        current_user&.id
      end

      def deal_json(deal, detailed: false)
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
          value: deal.value,
          stage: deal.stage,
          probability: deal.probability,
          expectedCloseDate: deal.expected_close_date&.iso8601,
          actualCloseDate: deal.actual_close_date&.iso8601,
          userId: deal.user_id,
          userName: deal.user&.name,
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
          updatedAt: deal.updated_at&.iso8601
        }
        
        if detailed
          base.merge!(
            products: deal.deal_products.map { |dp| deal_product_json(dp) },
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
