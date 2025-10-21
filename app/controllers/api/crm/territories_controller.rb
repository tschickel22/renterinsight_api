module Api
  module Crm
    class TerritoriesController < ApplicationController
      before_action :set_territory, only: [:show, :update, :destroy, :assign_user, :stats]

      # GET /api/crm/territories
      def index
        territories = Territory.includes(:territory_rules, :user, :territory_users)
                              .order(name: :asc)
        
        render json: territories.map { |t| territory_json(t) }
      end

      # GET /api/crm/territories/:id
      def show
        render json: territory_json(@territory, detailed: true)
      end

      # GET /api/crm/territories/:id/stats
      def stats
        # Calculate statistics for this territory
        deals = Deal.where(territory_id: @territory.id)
        
        total_value = deals.sum(:value)
        open_value = deals.open.sum(:value)
        won_value = deals.won.sum(:value)
        lost_value = deals.lost.sum(:value)
        
        open_count = deals.open.count
        won_count = deals.won.count
        lost_count = deals.lost.count
        
        closed_count = won_count + lost_count
        win_rate = closed_count > 0 ? (won_count.to_f / closed_count * 100).round(2) : 0
        
        render json: {
          territoryId: @territory.id,
          territoryName: @territory.name,
          totalValue: total_value,
          openValue: open_value,
          wonValue: won_value,
          lostValue: lost_value,
          openCount: open_count,
          wonCount: won_count,
          lostCount: lost_count,
          winRate: win_rate,
          avgDealValue: open_count > 0 ? (open_value / open_count).round(2) : 0
        }
      end

      # POST /api/crm/territories
      def create
        territory = Territory.new(territory_params.except(:assigned_to, :rules))
        
        if territory.save
          # Handle assigned users via join table
          if params[:territory][:assigned_to].present?
            user_ids = Array(params[:territory][:assigned_to]).map(&:to_i)
            user_ids.each do |user_id|
              territory.territory_users.create(user_id: user_id)
            end
          end
          
          # Handle rules if provided
          if params[:territory][:rules].present?
            params[:territory][:rules].each do |rule_params|
              territory.territory_rules.create(
                field: rule_params[:field],
                operator: rule_params[:operator],
                value: rule_params[:value],
                priority: rule_params[:priority] || 1,
                active: true
              )
            end
          end
          
          render json: territory_json(territory, detailed: true), status: :created
        else
          render json: { errors: territory.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/crm/territories/:id
      def update
        if @territory.update(territory_params.except(:assigned_to, :rules))
          # Handle assigned users via join table
          if params[:territory][:assigned_to].present?
            # Clear existing assignments
            @territory.territory_users.destroy_all
            
            # Create new assignments
            user_ids = Array(params[:territory][:assigned_to]).map(&:to_i)
            user_ids.each do |user_id|
              @territory.territory_users.create(user_id: user_id)
            end
          end
          
          # Handle rules update if provided
          if params[:territory][:rules].present?
            # Remove existing rules and create new ones
            @territory.territory_rules.destroy_all
            
            params[:territory][:rules].each do |rule_params|
              @territory.territory_rules.create(
                field: rule_params[:field],
                operator: rule_params[:operator],
                value: rule_params[:value],
                priority: rule_params[:priority] || 1,
                active: true
              )
            end
          end
          
          render json: territory_json(@territory, detailed: true)
        else
          render json: { errors: @territory.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/crm/territories/:id/assign_user
      def assign_user
        user_id = params[:user_id]
        
        if user_id.blank?
          render json: { error: 'User ID is required' }, status: :bad_request
          return
        end
        
        if @territory.update(user_id: user_id)
          render json: territory_json(@territory, detailed: true)
        else
          render json: { errors: @territory.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/territories/:id
      def destroy
        # Check if territory has deals
        if @territory.deals.exists?
          render json: { error: 'Cannot delete territory with existing deals' }, status: :unprocessable_entity
          return
        end
        
        @territory.destroy
        head :no_content
      end

      private

      def set_territory
        @territory = Territory.find(params[:id])
      end

      def territory_params
        params.require(:territory).permit(
          :name, :description, :user_id, :region, :type_field, :is_active,
          assigned_to: [],
          rules: [:id, :field, :operator, :value, :priority]
        )
      end

      def territory_json(territory, detailed: false)
        # Get assigned users from join table (safely handle if association doesn't exist)
        assigned_user_ids = begin
          territory.territory_users.pluck(:user_id).map(&:to_s)
        rescue => e
          Rails.logger.error("Error loading territory_users: #{e.message}")
          []
        end
        
        base = {
          id: territory.id,
          name: territory.name,
          description: territory.description,
          userId: territory.user_id,
          userName: territory.user&.name,
          region: territory.region,
          typeField: territory.type_field,
          assignedTo: assigned_user_ids,
          rules: territory.territory_rules.map { |r| territory_rule_json(r) },
          isActive: territory.is_active,
          dealsCount: territory.deals.count,
          openDealsValue: territory.deals.open.sum(:value),
          createdAt: territory.created_at&.iso8601,
          updatedAt: territory.updated_at&.iso8601
        }
        
        if detailed
          base.merge!(
            recentDeals: territory.deals.order(created_at: :desc).limit(5).map { |d| deal_summary_json(d) }
          )
        end
        
        base
      end

      def territory_rule_json(rule)
        {
          id: rule.id,
          field: rule.field,
          operator: rule.operator,
          value: rule.value,
          priority: rule.priority,
          active: rule.active
        }
      end

      def deal_summary_json(deal)
        {
          id: deal.id,
          name: deal.name,
          value: deal.value,
          stage: deal.stage,
          accountName: deal.account&.name
        }
      end
    end
  end
end
