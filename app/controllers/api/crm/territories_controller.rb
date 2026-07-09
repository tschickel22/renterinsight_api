# Territories are now company-scoped for proper multi-tenant isolation

module Api
  module Crm
    class TerritoriesController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm,
        read_actions: [:index, :show, :stats],
        create_actions: [:create],
        update_actions: [:update, :assign_user],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_territory, only: [:show, :update, :destroy, :assign_user, :stats]

      # GET /api/crm/territories
      def index
        # Company-scoped territories (includes company territories + global territories with nil company_id)
        territories = Territory.for_company(@company.id)
                              .includes(:territory_rules, :user, :territory_users)
                              .order(name: :asc)
        
        render json: territories.map { |t| territory_json(t) }
      end

      # GET /api/crm/territories/:id
      def show
        render json: territory_json(@territory, detailed: true)
      end

      # GET /api/crm/territories/:id/stats
      def stats
        # STRICT TENANT ISOLATION: Only count deals from current company
        deals = @company.deals.where(territory_id: @territory.id)
        
        total_value = deals.sum(:value)
        open_value = deals.open.sum(:value)
        won_value = deals.won(@company).sum(:value)
        lost_value = deals.lost(@company).sum(:value)

        open_count = deals.open.count
        won_count = deals.won(@company).count
        lost_count = deals.lost(@company).count
        
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
        # Create territory within current company
        territory = @company.territories.new(territory_params.except(:assigned_to, :rules))
        
        if territory.save
          # Handle assigned users via join table
          if params[:territory][:assigned_to].present?
            user_ids = Array(params[:territory][:assigned_to]).map(&:to_i)
            user_ids.each do |user_id|
              # Verify user belongs to same company
              if @company.users.exists?(user_id)
                territory.territory_users.create(user_id: user_id)
              end
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
            @territory.territory_users.destroy_all
            
            user_ids = Array(params[:territory][:assigned_to]).map(&:to_i)
            user_ids.each do |user_id|
              # Verify user belongs to same company
              if @company.users.exists?(user_id)
                @territory.territory_users.create(user_id: user_id)
              end
            end
          end
          
          # Handle rules update if provided
          if params[:territory][:rules].present?
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
        
        # Verify user belongs to same company
        unless @company.users.exists?(user_id)
          render json: { error: 'User not found or access denied' }, status: :not_found
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
        # Check if territory has deals in current company
        if @company.deals.where(territory_id: @territory.id).exists?
          render json: { error: 'Cannot delete territory with existing deals' }, status: :unprocessable_entity
          return
        end
        
        @territory.destroy
        head :no_content
      end

      private

      def set_company_scope
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def set_territory
        # Company-scoped territories (includes company territories + global territories)
        @territory = Territory.for_company(@company.id).find_by(id: params[:id])
        unless @territory
          render json: { error: 'Territory not found or access denied' }, status: :not_found
          return
        end
      end

      def territory_params
        params.require(:territory).permit(
          :name, :description, :user_id, :region, :type_field, :is_active,
          assigned_to: [],
          rules: [:id, :field, :operator, :value, :priority]
        )
      end

      def territory_json(territory, detailed: false)
        assigned_user_ids = begin
          territory.territory_users.pluck(:user_id).map(&:to_s)
        rescue => e
          Rails.logger.error("Error loading territory_users: #{e.message}")
          []
        end
        
        # STRICT TENANT ISOLATION: Scope deals count to company
        deals = @company.deals.where(territory_id: territory.id)
        
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
          dealsCount: deals.count,
          openDealsValue: deals.open.sum(:value),
          createdAt: territory.created_at&.iso8601,
          updatedAt: territory.updated_at&.iso8601
        }
        
        if detailed
          base.merge!(
            recentDeals: deals.order(created_at: :desc).limit(5).map { |d| deal_summary_json(d) }
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
