# frozen_string_literal: true

module Api
  module Platform
    class TenantSubscriptionsController < ApplicationController
      before_action :require_platform_admin!
      before_action :set_tenant
      before_action :set_subscription, only: [:show, :update, :cancel, :suspend, :activate]
      
      # GET /api/platform/tenants/:tenant_id/subscription
      def show
        if @subscription
          render json: { 
            subscription: @subscription.as_json_detailed,
            module_access: @tenant.module_access.as_json
          }
        else
          render json: { 
            subscription: nil,
            module_access: @tenant.module_access.as_json,
            message: 'No subscription assigned'
          }
        end
      end
      
      # POST /api/platform/tenants/:tenant_id/subscription
      def create
        if @tenant.tenant_subscription.present?
          render json: { error: 'Tenant already has a subscription' }, status: :unprocessable_entity
          return
        end
        
        plan = SubscriptionPlan.find(params[:plan_id])
        
        subscription = @tenant.build_tenant_subscription(
          subscription_plan: plan,
          status: params[:status] || 'active',
          billing_cycle: params[:billing_cycle] || 'monthly',
          zoho_subscription_id: params[:zoho_subscription_id],
          zoho_customer_id: params[:zoho_customer_id]
        )
        
        # Start trial if requested
        if params[:start_trial] == true
          subscription.status = 'trial'
          subscription.trial_ends_at = (params[:trial_days] || plan.trial_days || 14).days.from_now
        end
        
        if subscription.save
          subscription.refresh_usage!
          
          render json: { 
            subscription: subscription.as_json_detailed,
            message: 'Subscription created successfully'
          }, status: :created
        else
          render json: { errors: subscription.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/platform/tenants/:tenant_id/subscription
      def update
        return render_no_subscription unless @subscription
        
        # Change plan if provided
        if params[:plan_id].present?
          plan = SubscriptionPlan.find(params[:plan_id])
          @subscription.subscription_plan = plan
        end
        
        # Update other attributes
        @subscription.assign_attributes(subscription_params)
        
        if @subscription.save
          @subscription.refresh_usage!
          
          render json: { 
            subscription: @subscription.as_json_detailed,
            message: 'Subscription updated successfully'
          }
        else
          render json: { errors: @subscription.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # POST /api/platform/tenants/:tenant_id/subscription/cancel
      def cancel
        return render_no_subscription unless @subscription
        
        @subscription.cancel!(params[:reason])
        
        render json: { 
          subscription: @subscription.as_json_detailed,
          message: 'Subscription cancelled'
        }
      end
      
      # POST /api/platform/tenants/:tenant_id/subscription/suspend
      def suspend
        return render_no_subscription unless @subscription
        
        @subscription.suspend!
        
        render json: { 
          subscription: @subscription.as_json_detailed,
          message: 'Subscription suspended'
        }
      end
      
      # POST /api/platform/tenants/:tenant_id/subscription/activate
      def activate
        return render_no_subscription unless @subscription
        
        @subscription.activate!
        
        render json: { 
          subscription: @subscription.as_json_detailed,
          message: 'Subscription activated'
        }
      end
      
      # ==================
      # Module Overrides
      # ==================
      
      # GET /api/platform/tenants/:tenant_id/modules
      def modules
        render json: @tenant.module_access.as_json
      end
      
      # POST /api/platform/tenants/:tenant_id/modules/override
      def override_module
        module_key = params[:module_key]
        enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
        reason = params[:reason]
        
        unless PlatformModule.valid_key?(module_key)
          render json: { error: "Invalid module key: #{module_key}" }, status: :unprocessable_entity
          return
        end
        
        @tenant.module_access.set_override!(module_key, enabled, reason: reason, user: current_user)
        
        render json: { 
          module_access: @tenant.module_access.as_json,
          message: "Module '#{module_key}' overridden to #{enabled ? 'enabled' : 'disabled'}"
        }
      end
      
      # DELETE /api/platform/tenants/:tenant_id/modules/override/:module_key
      def remove_override
        module_key = params[:module_key]
        
        @tenant.module_access.remove_override!(module_key)
        
        render json: { 
          module_access: @tenant.module_access.as_json,
          message: "Override for '#{module_key}' removed"
        }
      end
      
      # PATCH /api/platform/tenants/:tenant_id/modules/config
      # Set module-level config (e.g., website_access_level for marketing.website)
      def update_module_config
        module_key = params[:module_key]
        config = params[:config]&.to_unsafe_h || {}

        unless PlatformModule.valid_key?(module_key)
          render json: { error: "Invalid module key: #{module_key}" }, status: :unprocessable_entity
          return
        end

        # Find or create override record for this module
        override = @tenant.tenant_module_overrides.find_or_initialize_by(module_key: module_key)
        override.is_enabled = true if override.new_record? # Default to enabled
        override.config = (override.config || {}).merge(config.deep_stringify_keys)
        override.override_reason = params[:reason] || "Config updated by platform admin"
        override.overridden_by = current_user

        if override.save
          render json: {
            module_access: @tenant.module_access.as_json,
            message: "Config for '#{module_key}' updated"
          }
        else
          render json: { errors: override.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/platform/tenants/:tenant_id/modules/bulk_override
      def bulk_override
        overrides = params[:overrides] || {}
        reason = params[:reason]
        
        @tenant.module_access.set_overrides!(overrides, reason: reason, user: current_user)
        
        render json: { 
          module_access: @tenant.module_access.as_json,
          message: "#{overrides.keys.count} module overrides applied"
        }
      end
      
      private
      
      def set_tenant
        @tenant = ::Company.find(params[:tenant_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Tenant not found' }, status: :not_found
      end
      
      def set_subscription
        @subscription = @tenant.tenant_subscription
      end
      
      def subscription_params
        params.permit(
          :billing_cycle, :status,
          :zoho_subscription_id, :zoho_customer_id,
          :current_period_start, :current_period_end,
          :trial_ends_at
        )
      end
      
      def render_no_subscription
        render json: { error: 'Tenant has no subscription' }, status: :not_found
      end
    end
  end
end
