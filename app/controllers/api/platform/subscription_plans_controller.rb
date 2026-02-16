# frozen_string_literal: true

module Api
  module Platform
    class SubscriptionPlansController < ApplicationController
      before_action :require_platform_admin!
      before_action :set_plan, only: [:show, :update, :destroy, :set_modules, :set_module_config]
      
      # GET /api/platform/subscription_plans
      def index
        plans = SubscriptionPlan.ordered.with_modules
        plans = plans.active if params[:active_only] == 'true'
        
        render json: {
          plans: plans.map(&:as_json_with_modules),
          total: plans.count
        }
      end
      
      # GET /api/platform/subscription_plans/:id
      def show
        render json: { plan: @plan.as_json_with_modules }
      end
      
      # POST /api/platform/subscription_plans
      def create
        plan = SubscriptionPlan.new(plan_params)
        
        if plan.save
          # Set modules if provided
          if params[:modules].present?
            set_plan_modules(plan, params[:modules])
          elsif params[:template].present?
            # Use template modules
            plan.set_enabled_modules(PlatformModule.template_modules(params[:template]))
          end
          
          # Set module configs if provided (e.g., website_access_level)
          set_plan_module_configs(plan, params[:module_configs]) if params[:module_configs].present?
          
          render json: { 
            plan: plan.reload.as_json_with_modules,
            message: 'Subscription plan created successfully'
          }, status: :created
        else
          render json: { errors: plan.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/platform/subscription_plans/:id
      def update
        if @plan.update(plan_params)
          # Update modules if provided
          set_plan_modules(@plan, params[:modules]) if params[:modules].present?
          
          # Update module configs if provided
          set_plan_module_configs(@plan, params[:module_configs]) if params[:module_configs].present?
          
          render json: { 
            plan: @plan.reload.as_json_with_modules,
            message: 'Subscription plan updated successfully'
          }
        else
          render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/platform/subscription_plans/:id
      def destroy
        # Check if plan has active subscriptions
        if @plan.tenant_subscriptions.active.exists?
          render json: { 
            error: 'Cannot delete plan with active subscriptions',
            active_count: @plan.tenant_subscriptions.active.count
          }, status: :unprocessable_entity
          return
        end
        
        @plan.destroy!
        render json: { message: 'Subscription plan deleted successfully' }
      end
      
      # POST /api/platform/subscription_plans/:id/set_modules
      def set_modules
        modules_hash = params[:modules] || {}
        set_plan_modules(@plan, modules_hash)
        
        render json: { 
          plan: @plan.reload.as_json_with_modules,
          message: 'Modules updated successfully'
        }
      end
      
      # PATCH /api/platform/subscription_plans/:id/set_module_config
      # Set config for a specific module on this plan (e.g., website_access_level)
      def set_module_config
        module_key = params[:module_key]
        config = params[:config]&.to_unsafe_h || {}

        unless PlatformModule.valid_key?(module_key)
          render json: { error: "Invalid module key: #{module_key}" }, status: :unprocessable_entity
          return
        end

        mod = @plan.subscription_plan_modules.find_or_initialize_by(module_key: module_key)
        mod.is_enabled = true if mod.new_record?
        mod.config = (mod.config || {}).merge(config.deep_stringify_keys)

        if mod.save
          render json: {
            plan: @plan.reload.as_json_with_modules,
            message: "Config for '#{module_key}' updated on plan '#{@plan.display_name}'"
          }
        else
          render json: { errors: mod.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/platform/subscription_plans/modules
      def modules
        render json: PlatformModule.as_json_with_categories
      end
      
      # GET /api/platform/subscription_plans/templates
      def templates
        render json: {
          templates: {
            starter: PlatformModule.template_modules(:starter),
            professional: PlatformModule.template_modules(:professional),
            enterprise: PlatformModule.template_modules(:enterprise)
          }
        }
      end
      
      private
      
      def set_plan
        @plan = SubscriptionPlan.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Plan not found' }, status: :not_found
      end
      
      def plan_params
        params.require(:plan).permit(
          :name, :display_name, :description, :category,
          :zoho_plan_code, :zoho_product_id,
          :pricing_monthly, :pricing_annual, :currency, :billing_model,
          :max_users, :max_storage_gb, :max_locations, :max_api_calls,
          :trial_enabled, :trial_days, :setup_fee,
          :discount_type, :discount_value, :zoho_coupon_code,
          :is_active, :is_popular, :position,
          metadata: {}
        )
      end
      
      def set_plan_modules(plan, modules_hash)
        modules_hash.each do |key, enabled|
          next unless PlatformModule.valid_key?(key.to_s)
          
          mod = plan.subscription_plan_modules.find_or_initialize_by(module_key: key.to_s)
          mod.is_enabled = ActiveModel::Type::Boolean.new.cast(enabled)
          mod.save!
        end
      end

      def set_plan_module_configs(plan, configs_hash)
        configs_hash.each do |module_key, config|
          next unless PlatformModule.valid_key?(module_key.to_s)
          next if config.blank?

          mod = plan.subscription_plan_modules.find_or_initialize_by(module_key: module_key.to_s)
          mod.is_enabled = true if mod.new_record?
          mod.config = (mod.config || {}).merge(config.is_a?(Hash) ? config : config.to_unsafe_h).deep_stringify_keys
          mod.save!
        end
      end
    end
  end
end
