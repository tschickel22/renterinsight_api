# frozen_string_literal: true

module Api
  module V1
    class CommissionComponentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_component, only: [:show, :update, :destroy, :toggle, :calculate]
      
      # GET /api/v1/commission_components
      def index
        return unless authorize_action!('commission_components', 'read')
        
        components = @company.commission_components
        
        # Filter by location if specified
        if params[:location_id].present?
          components = components.where(location_id: params[:location_id])
        end
        
        # Filter by active status
        if params[:active].present?
          components = params[:active] == 'true' ? components.active : components.inactive
        end
        
        # Apply location selector filter
        components = components.for_current_location if Current.location_filtered?
        
        # Order by sequence
        components = components.ordered
        
        render json: {
          components: components.map { |c| component_json(c) },
          meta: {
            total: components.count,
            company_wide_count: components.company_wide.count,
            location_specific_count: components.location_specific.count
          }
        }
      end
      
      # GET /api/v1/commission_components/:id
      def show
        return unless authorize_action!('commission_components', 'read')
        
        render json: { component: component_json(@component, detailed: true) }
      end
      
      # POST /api/v1/commission_components
      def create
        return unless authorize_action!('commission_components', 'create')
        
        component = @company.commission_components.build(component_params)
        
        # Auto-assign location_id if filtered
        component.location_id ||= Current.location_id if Current.location_id.present?
        
        if component.save
          render json: { component: component_json(component, detailed: true) }, status: :created
        else
          render json: { errors: component.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/commission_components/:id
      def update
        return unless authorize_action!('commission_components', 'update')
        
        if @component.update(component_params)
          render json: { component: component_json(@component, detailed: true) }
        else
          render json: { errors: @component.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/commission_components/:id
      def destroy
        return unless authorize_action!('commission_components', 'delete')
        
        @component.destroy
        head :no_content
      end
      
      # POST /api/v1/commission_components/:id/toggle
      def toggle
        return unless authorize_action!('commission_components', 'update')
        
        @component.update!(is_active: !@component.is_active)
        render json: { component: component_json(@component) }
      end
      
      # POST /api/v1/commission_components/:id/calculate
      # Test calculation with a sample deal
      def calculate
        return unless authorize_action!('commission_components', 'read')
        
        deal_id = params[:deal_id]
        
        unless deal_id.present?
          render json: { error: 'deal_id required' }, status: :bad_request
          return
        end
        
        deal = @company.deals.find(deal_id)

        # The engine that makes the payments (CommissionCalculationService
        # read every component in the company, not the deal's plan, and
        # disagreed with what was paid). Same response shape as before.
        engine = CommissionPaymentGeneratorService.new(deal)
        line = engine.component_line(@component)
        render json: {
          deal_id: deal.id,
          deal_identifier: deal.name || "Deal ##{deal.id}",
          payee_user_id: deal.primary_salesperson_id,
          total_commission: line[:amount].to_f,
          line_items: [{
            component_id: @component.id, component_name: @component.name,
            component_type: @component.component_type,
            gross_type: @component.component_type == 'addon_commission' ? 'addon' : @component.gross_type,
            rate: @component.rate&.to_f, amount: line[:amount].to_f, note: line[:note]
          }.compact],
          plan: deal.commission_plan && {
            id: deal.commission_plan_id, name: deal.commission_plan.name,
            primary_salesperson_total: engine.total_for_role(:primary_salesperson).to_f
          },
          deal_economics: {
            selling_price: deal.selling_price, cost: deal.unit_cost, front_gross: deal.front_gross,
            pack: deal.effective_pack_amount, commissionable_front_gross: deal.commissionable_front_gross,
            back_gross: deal.back_gross, total_gross: deal.total_gross, addon_gross: deal.addon_gross,
            quantity: deal.quantity
          }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end
      
      # GET /api/v1/commission_components/options
      def options
        render json: {
          component_types: CommissionComponent::COMPONENT_TYPES.map { |t| { value: t, label: t.humanize } },
          gross_types: CommissionComponent::GROSS_TYPES.map { |t| { value: t, label: t.humanize } },
          roles: CommissionComponent::ROLES.map { |r| { value: r, label: r.humanize } },
          deal_types: CommissionComponent::DEAL_TYPES.map { |d| { value: d, label: d.upcase } },
          verticals: CommissionComponent::VERTICALS.map { |v| { value: v, label: v.upcase } },
          threshold_periods: CommissionComponent::THRESHOLD_PERIODS.map { |p| { value: p, label: p.humanize } }
        }
      end
      
      private
      
      def set_component
        @component = @company.commission_components.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Component not found' }, status: :not_found
      end
      
      def component_params
        params.require(:component).permit(
          :name,
          :component_type,
          :applies_to_role,
          :is_active,
          :gross_type,
          :rate,
          :flat_amount,
          :units_threshold,
          :threshold_period,
          :deal_type,
          :vertical,
          :sequence,
          :description,
          :location_id
        )
      end
      
      def component_json(component, detailed: false)
        base = {
          id: component.id,
          name: component.name,
          displayName: component.display_name,
          componentType: component.component_type,
          appliesToRole: component.applies_to_role,
          isActive: component.is_active,
          scopeLevel: component.scope_level,
          locationId: component.location_id,
          locationName: component.location&.name,
          sequence: component.sequence,
          calculationDescription: component.calculation_description,
          
          # Type-specific fields
          grossType: component.gross_type,
          rate: component.rate,
          ratePercent: component.rate ? (component.rate * 100).round(2) : nil,
          flatAmount: component.flat_amount,
          unitsThreshold: component.units_threshold,
          thresholdPeriod: component.threshold_period,
          
          # Filters
          dealType: component.deal_type,
          vertical: component.vertical,
          
          createdAt: component.created_at&.iso8601,
          updatedAt: component.updated_at&.iso8601
        }
        
        if detailed
          base[:description] = component.description
        end
        
        base
      end
    end
  end
end
