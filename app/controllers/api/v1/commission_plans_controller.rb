# frozen_string_literal: true

module Api
  module V1
    class CommissionPlansController < ApplicationController
      before_action :set_company_scope
      before_action :set_commission_plan, only: [:show, :update, :destroy, :activate, :deactivate, :components, :available_components, :add_component, :remove_component, :reorder_components]

      # GET /api/v1/commission-plans
      def index
        return unless authorize_action!('commission_plans', 'read')
        
        plans = @company.commission_plans
        
        # Apply location filter
        plans = plans.for_current_location if plans.respond_to?(:for_current_location)
        
        # Filter by status
        case params[:status]
        when 'active'
          plans = plans.active
        when 'inactive'
          plans = plans.where(is_active: false)
        when 'current'
          plans = plans.current
        when 'default'
          plans = plans.defaults
        end
        
        # Filter by assignment
        if params[:assigned_user_id].present?
          plans = plans.where(assigned_user_id: params[:assigned_user_id])
        end
        
        if params[:assigned_role].present?
          plans = plans.where(assigned_role: params[:assigned_role])
        end
        
        # Search by name
        if params[:search].present?
          plans = plans.where('name ILIKE ?', "%#{params[:search]}%")
        end
        
        plans = plans.includes(:commission_components, :location).order(display_order: :asc, created_at: :desc)
        
        render json: {
          plans: plans.map { |plan| serialize_plan(plan, detailed: false) }
        }
      end

      # GET /api/v1/commission-plans/:id
      def show
        return unless authorize_action!('commission_plans', 'read')
        
        render json: serialize_plan(@plan, detailed: true)
      end

      # POST /api/v1/commission-plans
      def create
        return unless authorize_action!('commission_plans', 'create')
        
        plan = @company.commission_plans.new(plan_params)
        
        # Auto-assign location from selector if present
        plan.location_id ||= Current.location_id if Current.location_id.present?
        
        if plan.save
          render json: serialize_plan(plan, detailed: true), status: :created
        else
          render json: { errors: plan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/commission-plans/:id
      def update
        return unless authorize_action!('commission_plans', 'update')
        
        if @plan.update(plan_params)
          render json: serialize_plan(@plan, detailed: true)
        else
          render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/commission-plans/:id
      def destroy
        return unless authorize_action!('commission_plans', 'delete')
        
        # Check if plan has commission payments
        if @plan.commission_payments.any?
          render json: { 
            error: 'Cannot delete plan with associated commission payments. Deactivate instead.' 
          }, status: :unprocessable_entity
          return
        end
        
        # Check if plan has components
        if @plan.commission_components.any?
          render json: {
            error: 'Cannot delete plan with associated components. Remove components first or deactivate plan.'
          }, status: :unprocessable_entity
          return
        end
        
        @plan.destroy
        head :no_content
      end

      # POST /api/v1/commission-plans/:id/activate
      def activate
        return unless authorize_action!('commission_plans', 'update')
        
        if @plan.update(is_active: true)
          render json: serialize_plan(@plan, detailed: true)
        else
          render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/commission-plans/:id/deactivate
      def deactivate
        return unless authorize_action!('commission_plans', 'update')
        
        if @plan.update(is_active: false)
          render json: serialize_plan(@plan, detailed: true)
        else
          render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/commission-plans/stats
      def stats
        return unless authorize_action!('commission_plans', 'read')
        
        plans = @company.commission_plans
        plans = plans.for_current_location if Current.location_filtered?
        
        active_plans = plans.active
        current_plans = active_plans.current
        
        render json: {
          total: plans.count,
          active: active_plans.count,
          inactive: plans.where(is_active: false).count,
          current: current_plans.count,
          expired: active_plans.where('expiration_date < ?', Date.today).count,
          future: active_plans.where('effective_date > ?', Date.today).count,
          default_plans: plans.defaults.count,
          user_specific: plans.where.not(assigned_user_id: nil).count,
          role_specific: plans.where.not(assigned_role: nil).count
        }
      end

      # GET /api/v1/commission-plans/:id/components
      # Returns all components linked to this plan
      def components
        return unless authorize_action!('commission_plans', 'read')

        components = @plan.commission_components
          .where(is_active: true)
          .order(:sequence, :id)

        render json: {
          planId: @plan.id,
          planName: @plan.name,
          components: components.map { |c| serialize_component(c) }
        }
      end

      # GET /api/v1/commission-plans/:id/available_components
      # Returns components NOT yet linked to this plan
      def available_components
        return unless authorize_action!('commission_plans', 'read')

        # Get all active components not linked to this plan
        available = @company.commission_components
          .where(is_active: true)
          .where('commission_plan_id IS NULL OR commission_plan_id != ?', @plan.id)
          .order(:name)

        # Apply location filter if present
        if Current.location_filtered?
          available = available.where(
            'location_id = ? OR location_id IS NULL',
            Current.location_id
          )
        end

        render json: {
          components: available.map { |c| serialize_component(c) }
        }
      end

      # POST /api/v1/commission-plans/:id/add_component
      # Body: { component_id: 123 } or { component_ids: [123, 456] }
      # Links existing component(s) to this plan
      def add_component
        return unless authorize_action!('commission_plans', 'update')

        component_ids = if params[:component_ids].present?
          params[:component_ids]
        elsif params[:component_id].present?
          [params[:component_id]]
        else
          return render json: { error: 'component_id or component_ids required' }, status: :unprocessable_entity
        end

        components = @company.commission_components
          .where(id: component_ids, is_active: true)

        if components.empty?
          return render json: { error: 'No valid components found' }, status: :not_found
        end

        # Get next sequence number
        max_sequence = @plan.commission_components.maximum(:sequence) || 0

        added_count = 0
        components.each do |component|
          # Skip if already linked
          next if component.commission_plan_id == @plan.id

          # Update component to link to this plan
          if component.update(
            commission_plan_id: @plan.id,
            sequence: max_sequence + added_count + 1
          )
            added_count += 1
          end
        end

        if added_count > 0
          render json: {
            message: "Added #{added_count} component(s) to plan",
            plan: serialize_plan(@plan, detailed: false),
            components: @plan.commission_components.order(:sequence).map { |c| serialize_component(c) }
          }
        else
          render json: { error: 'Components already linked to this plan' }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/commission-plans/:id/remove_component/:component_id
      # Unlinks component from plan (doesn't delete the component)
      def remove_component
        return unless authorize_action!('commission_plans', 'update')

        component = @plan.commission_components.find_by(id: params[:component_id])

        if component.nil?
          return render json: { error: 'Component not found in this plan' }, status: :not_found
        end

        # Check if component is used in any payments
        if component.commission_payment_line_items.exists?
          return render json: {
            error: 'Cannot remove component that has been used in commission payments'
          }, status: :unprocessable_entity
        end

        # Unlink from plan (set commission_plan_id to null)
        if component.update(commission_plan_id: nil, sequence: 0)
          # Resequence remaining components
          resequence_plan_components(@plan)

          render json: {
            message: 'Component removed from plan',
            plan: serialize_plan(@plan, detailed: false),
            components: @plan.commission_components.reload.order(:sequence).map { |c| serialize_component(c) }
          }
        else
          render json: { errors: component.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/commission-plans/:id/reorder_components
      # Body: { component_sequence: [{ id: 123, sequence: 1 }, { id: 456, sequence: 2 }] }
      # Updates sequence order of components in plan
      def reorder_components
        return unless authorize_action!('commission_plans', 'update')

        sequences = params[:component_sequence]

        if sequences.blank? || !sequences.is_a?(Array)
          return render json: { error: 'component_sequence array required' }, status: :unprocessable_entity
        end

        updated_count = 0
        sequences.each do |item|
          component = @plan.commission_components.find_by(id: item[:id])
          if component && component.update(sequence: item[:sequence])
            updated_count += 1
          end
        end

        render json: {
          message: "Updated sequence for #{updated_count} component(s)",
          components: @plan.commission_components.reload.order(:sequence).map { |c| serialize_component(c) }
        }
      end

      private

      def set_commission_plan
        @plan = @company.commission_plans.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Commission plan not found' }, status: :not_found
      end

      def plan_params
        params.require(:commission_plan).permit(
          :name,
          :description,
          :is_active,
          :is_default,
          :effective_date,
          :expiration_date,
          :assigned_user_id,
          :assigned_role,
          :location_id,
          :display_order,
          metadata: {}
        )
      end

      def serialize_plan(plan, detailed: false)
        base = {
          id: plan.id,
          name: plan.name,
          description: plan.description,
          isActive: plan.is_active,
          isDefault: plan.is_default,
          effectiveDate: plan.effective_date&.iso8601,
          expirationDate: plan.expiration_date&.iso8601,
          assignedUserId: plan.assigned_user_id,
          assignedUserName: plan.assigned_user&.name,
          assignedRole: plan.assigned_role,
          locationId: plan.location_id,
          locationName: plan.location&.name,
          displayOrder: plan.display_order,
          status: plan_status(plan),
          componentCount: plan.commission_components.count,
          activeComponentCount: plan.commission_components.active.count,
          paymentCount: plan.commission_payments.count,
          metadata: plan.metadata,
          createdAt: plan.created_at&.iso8601,
          updatedAt: plan.updated_at&.iso8601
        }
        
        if detailed
          base[:components] = plan.commission_components.ordered.map do |component|
            serialize_component(component)
          end
        end
        
        base
      end

      def serialize_component(component)
        {
          id: component.id,
          name: component.name,
          description: component.description,
          componentType: component.component_type,
          grossType: component.gross_type,
          rate: component.rate&.to_f,
          flatAmount: component.flat_amount&.to_f,
          appliesToRole: component.applies_to_role,
          dealType: component.deal_type,
          vertical: component.vertical,
          unitsThreshold: component.units_threshold,
          thresholdPeriod: component.threshold_period,
          sequence: component.sequence,
          isActive: component.is_active,
          calculationDescription: component.calculation_description,
          displayName: component.display_name
        }
      end

      def plan_status(plan)
        return 'inactive' unless plan.is_active
        return 'expired' if plan.expiration_date && plan.expiration_date < Date.today
        return 'future' if plan.effective_date && plan.effective_date > Date.today
        'current'  # Active and within date range (or no dates set)
      end

      def resequence_plan_components(plan)
        # Reorder remaining components sequentially
        plan.commission_components.order(:sequence, :id).each_with_index do |component, index|
          component.update_column(:sequence, index + 1)
        end
      end
    end
  end
end
