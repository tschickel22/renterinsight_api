# frozen_string_literal: true

module Api
  class SettingsController < ApplicationController
    before_action :set_company
    
    # RBAC Authorization - tenant_basic is accessible by any authenticated company user
    before_action :authorize_settings_read!, only: [:tenant, :platform, :quotes, :custom_fields, :show_scoped]
    before_action :authorize_settings_update!, only: [:update, :update_quotes]
    before_action :authorize_branding_read!, only: []  # No read-only branding endpoints here
    before_action :authorize_branding_update!, only: [:update_branding]
    before_action :authorize_custom_fields_create!, only: [:create_custom_field]
    before_action :authorize_custom_fields_update!, only: [:update_custom_field]
    before_action :authorize_custom_fields_delete!, only: [:destroy_custom_field]

    # GET /api/settings/tenant_basic
    # Returns minimal tenant info needed by all authenticated users (no company_settings permission required)
    def tenant_basic
      Rails.logger.info "🏢 [SettingsController#tenant_basic] Loading basic tenant info for company: #{@company.name} (ID: #{@company.id})"
      
      render json: {
        tenant: serialize_tenant_basic
      }
    rescue => e
      Rails.logger.error "Tenant basic settings error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      render json: { 
        error: 'Failed to load tenant settings',
        details: Rails.env.development? ? e.message : nil
      }, status: :internal_server_error
    end

    # GET /api/settings/tenant
    # Full tenant settings - requires company_settings permission
    def tenant
      Rails.logger.info "🏢 [SettingsController#tenant] Loading tenant for company: #{@company.name} (ID: #{@company.id})"
      
      render json: {
        tenant: serialize_tenant
      }
    rescue => e
      Rails.logger.error "Tenant settings error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      render json: { 
        error: 'Failed to load tenant settings',
        details: Rails.env.development? ? e.message : nil
      }, status: :internal_server_error
    end

    # GET /api/settings/platform
    def platform
      settings_hash = {
        communications: {},
        operational: {},
        branding: {},
        integrations: {}
      }

      Setting.where(scope_type: 'Platform', scope_id: 0).each do |setting|
        begin
          value = JSON.parse(setting.value)
          settings_hash[setting.key.to_sym] = value
        rescue JSON::ParserError => e
          Rails.logger.error "Failed to parse platform setting #{setting.key}: #{e.message}"
        end
      end

      render json: settings_hash
    rescue => e
      Rails.logger.error "Platform settings error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      render json: { 
        error: 'Failed to load platform settings',
        details: Rails.env.development? ? e.message : nil
      }, status: :internal_server_error
    end

    # GET /api/settings/scoped?key=...&scope_type=...&scope_id=...
    # Fetch a single setting by key + scope
    def show_scoped
      key = params[:key]
      scope_type = params[:scope_type] || 'Company'
      scope_id = params[:scope_id] || @company.id

      unless key.present?
        return render json: { error: 'key parameter is required' }, status: :unprocessable_entity
      end

      # Security: validate scope access
      if scope_type == 'Company' && scope_id.to_s != @company.id.to_s
        return render json: { error: 'Unauthorized' }, status: :forbidden
      end

      if scope_type == 'Location'
        unless @company.locations.exists?(id: scope_id)
          return render json: { error: 'Unauthorized: Location not found or access denied' }, status: :forbidden
        end
      end

      value = Setting.get(scope_type, scope_id, key)
      render json: { key: key, value: value }
    end

    # PATCH /api/settings (old format)
    # PUT /api/settings (new format)
    def update
      Rails.logger.info "🔧 [SettingsController#update] Received params: #{params.inspect}"
      Rails.logger.info "🔧 [SettingsController#update] Company: #{@company&.name} (ID: #{@company&.id})"
      
      # Handle company attribute updates (name, domain)
      if params[:name].present? || params[:domain].present?
        Rails.logger.info "🏢 [SettingsController#update] Updating company attributes: name=#{params[:name]}, domain=#{params[:domain]}"
        company_params = {}
        company_params[:name] = params[:name] if params[:name].present?
        company_params[:domain] = params[:domain] if params[:domain].present?
        
        if @company.update(company_params)
          Rails.logger.info "✅ [SettingsController#update] Company updated successfully: #{@company.name}"
          render json: {
            tenant: serialize_tenant,
            message: 'Company updated successfully'
          }
        else
          Rails.logger.error "❌ [SettingsController#update] Company update failed: #{@company.errors.full_messages}"
          render json: {
            errors: @company.errors.full_messages
          }, status: :unprocessable_entity
        end
        return
      end
      
      if params[:key].present? && params[:value].present?
        scope_type = params[:scope_type] || 'Company'
        scope_id = params[:scope_id] || @company.id
        key = params[:key]
        value = params[:value]
        
        # Security: Validate scope access
        if scope_type == 'Company' && scope_id.to_s != @company.id.to_s
          Rails.logger.error "🚫 [SettingsController] Unauthorized: User trying to access company #{scope_id} but authenticated for company #{@company.id}"
          render json: { error: 'Unauthorized' }, status: :forbidden
          return
        end
        
        # Security: Validate location belongs to current company
        if scope_type == 'Location'
          location = @company.locations.find_by(id: scope_id)
          unless location
            Rails.logger.error "🚫 [SettingsController] Unauthorized: Location #{scope_id} not found or doesn't belong to company #{@company.id}"
            render json: { error: 'Unauthorized: Location not found or access denied' }, status: :forbidden
            return
          end
        end
        
        Rails.logger.info "✅ [SettingsController] Updating setting: scope=#{scope_type}:#{scope_id}, key=#{key}"
        Setting.set(scope_type, scope_id, key, value)
        
        render json: {
          setting: {
            scope_type: scope_type,
            scope_id: scope_id,
            key: key,
            value: value
          },
          message: 'Settings updated successfully'
        }
      elsif params[:settings].present?
        settings_params = params.require(:settings).permit!
        
        settings_params.each do |key, value|
          Setting.set('Company', @company.id, key, value)
        end

        render json: {
          tenant: serialize_tenant
        }
      else
        render json: { error: 'Invalid params format' }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.error "Settings update error: #{e.message}\n#{e.backtrace.join("\n")}"
      render json: {
        error: e.message
      }, status: :internal_server_error
    end

    # DELETE /api/settings
    def destroy
      key = params[:key]
      scope_type = params[:scope_type] || 'Company'
      scope_id = params[:scope_id] || @company.id
      
      unless key.present?
        render json: { error: 'Key parameter is required' }, status: :unprocessable_entity
        return
      end
      
      allowed_keys = ['communications', 'operational', 'branding', 'integrations']
      unless allowed_keys.include?(key)
        render json: { error: "Invalid key. Allowed keys: #{allowed_keys.join(', ')}" }, status: :unprocessable_entity
        return
      end
      
      # Security: Validate scope access
      if scope_type == 'Company' && scope_id.to_s != @company.id.to_s
        Rails.logger.error "🚫 [SettingsController] Unauthorized: User trying to delete company #{scope_id} settings but authenticated for company #{@company.id}"
        render json: { error: 'Unauthorized' }, status: :forbidden
        return
      end
      
      # Security: Validate location belongs to current company
      if scope_type == 'Location'
        location = @company.locations.find_by(id: scope_id)
        unless location
          Rails.logger.error "🚫 [SettingsController] Unauthorized: Location #{scope_id} not found or doesn't belong to company #{@company.id}"
          render json: { error: 'Unauthorized: Location not found or access denied' }, status: :forbidden
          return
        end
      end
      
      deleted_count = Setting.where(
        scope_type: scope_type,
        scope_id: scope_id,
        key: key
      ).delete_all
      
      Rails.logger.info "✅ [SettingsController] Reset #{key} for #{scope_type} #{scope_id}: deleted #{deleted_count} setting(s)"
      
      render json: {
        message: "Settings for '#{key}' have been reset to #{scope_type == 'Location' ? 'company or platform' : 'platform'} defaults",
        key: key,
        scope_type: scope_type,
        scope_id: scope_id,
        deleted_count: deleted_count
      }
    rescue => e
      Rails.logger.error "Settings delete error: #{e.message}\n#{e.backtrace.join("\n")}"
      render json: {
        error: e.message
      }, status: :internal_server_error
    end

    # PATCH /api/settings/branding
    def update_branding
      branding_params = params.require(:branding).permit(
        :primaryColor, :secondaryColor, :fontFamily, :logo, :favicon, :faviconUrl,
        :sideMenuColor, :portalName, :portalLogo
      )

      # Normalize favicon: if faviconUrl is provided, also set favicon
      if branding_params[:faviconUrl].present?
        branding_params[:favicon] = branding_params[:faviconUrl]
      elsif branding_params[:favicon].present?
        branding_params[:faviconUrl] = branding_params[:favicon]
      end

      Setting.set('Company', @company.id, 'branding', branding_params.to_h)

      render json: {
        tenant: serialize_tenant
      }
    end

    # GET /api/settings/quotes
    def quotes
      quotes_setting = ::Setting.get('Company', @company.id, 'quotes', {})
      
      default_quotes = {
        defaultTaxRate: 0,
        defaultTermsConditions: '',
        defaultValidityDays: 30,
        companyName: @company.name,
        logoUrl: '',
        companyAddress: '',
        companyCity: '',
        companyState: '',
        companyZip: '',
        companyPhone: '',
        companyEmail: '',
        companyWebsite: ''
      }
      
      render json: default_quotes.merge(quotes_setting.deep_symbolize_keys)
    end

    # PATCH /api/settings/quotes
    def update_quotes
      quotes_params = params.require(:quotes).permit(
        :defaultTaxRate, :defaultTermsConditions, :defaultValidityDays,
        :companyName, :logoUrl, :companyAddress, :companyCity,
        :companyState, :companyZip, :companyPhone, :companyEmail,
        :companyWebsite
      )

      Setting.set('Company', @company.id, 'quotes', quotes_params.to_h)

      render json: {
        tenant: serialize_tenant
      }
    end

    # GET /api/settings/pipeline_stages
    def pipeline_stages
      stages = Setting.get('Company', @company.id, 'pipeline_stages', nil)

      if stages.nil?
        stages = [
          { key: 'lead',         name: 'Lead',         probability: 10,  color: '#94a3b8', locked: false, order: 0 },
          { key: 'qualified',    name: 'Qualified',    probability: 25,  color: '#60a5fa', locked: false, order: 1 },
          { key: 'proposal',     name: 'Proposal',     probability: 50,  color: '#f59e0b', locked: false, order: 2 },
          { key: 'negotiation',  name: 'Negotiation',  probability: 75,  color: '#f97316', locked: false, order: 3 },
          { key: 'won',          name: 'Won',          probability: 100, color: '#22c55e', locked: true,  order: 4 },
          { key: 'lost',         name: 'Lost',         probability: 0,   color: '#ef4444', locked: true,  order: 5 }
        ]
      end

      render json: { stages: stages }
    end

    # PATCH /api/settings/pipeline_stages
    def update_pipeline_stages
      stages = params[:stages]

      unless stages.is_a?(Array)
        render json: { error: 'stages must be an array' }, status: :unprocessable_entity
        return
      end

      Setting.set('Company', @company.id, 'pipeline_stages', stages)
      render json: { stages: stages, message: 'Pipeline stages saved successfully' }
    rescue => e
      render json: { error: e.message }, status: :internal_server_error
    end

    # GET /api/settings/custom_fields
    def custom_fields
      module_name = params[:module]
      
      fields = if module_name.present?
        @company.custom_fields.for_module(module_name).ordered
      else
        @company.custom_fields.ordered
      end

      render json: {
        custom_fields: fields.as_json
      }
    end

    # POST /api/settings/custom_fields
    def create_custom_field
      field_params = params.require(:custom_field).permit(
        :module, :name, :label, :field_type, :required, 
        :default_value, :display_order, options: []
      )

      field = @company.custom_fields.create!(field_params)

      render json: {
        custom_field: field.as_json
      }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # PATCH /api/settings/custom_fields/:id
    def update_custom_field
      field = @company.custom_fields.find(params[:id])
      
      field_params = params.require(:custom_field).permit(
        :label, :field_type, :required, :default_value, 
        :display_order, options: []
      )

      field.update!(field_params)

      render json: {
        custom_field: field.as_json
      }
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Custom field not found' }, status: :not_found
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # DELETE /api/settings/custom_fields/:id
    def destroy_custom_field
      field = @company.custom_fields.find(params[:id])
      field.destroy!

      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Custom field not found' }, status: :not_found
    end

    private

    # ============================================
    # RBAC Authorization Methods
    # ============================================
    
    def authorize_settings_read!
      return if skip_rbac?
      unless current_user.has_permission?('company_settings', 'read', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied READ access to company_settings for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to view company settings' }, status: :forbidden
      end
    end

    def authorize_settings_update!
      return if skip_rbac?
      unless current_user.has_permission?('company_settings', 'update', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied UPDATE access to company_settings for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to modify company settings' }, status: :forbidden
      end
    end

    def authorize_branding_update!
      return if skip_rbac?
      unless current_user.has_permission?('branding', 'update', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied UPDATE access to branding for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to modify branding settings' }, status: :forbidden
      end
    end

    def authorize_custom_fields_create!
      return if skip_rbac?
      unless current_user.has_permission?('company_settings', 'create', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied CREATE access to custom_fields for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to create custom fields' }, status: :forbidden
      end
    end

    def authorize_custom_fields_update!
      return if skip_rbac?
      unless current_user.has_permission?('company_settings', 'update', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied UPDATE access to custom_fields for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to modify custom fields' }, status: :forbidden
      end
    end

    def authorize_custom_fields_delete!
      return if skip_rbac?
      unless current_user.has_permission?('company_settings', 'delete', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied DELETE access to custom_fields for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to delete custom fields' }, status: :forbidden
      end
    end

    def skip_rbac?
      return true if current_user.platform_admin?
      return true if current_user.super_admin?
      return true unless @company&.use_rbac_system
      false
    end

    # ============================================
    # Company Setup
    # ============================================

    def set_company
      selected_company_id = (request.headers['X-Company-ID'] || request.headers['X-Company-Context'])&.to_i
      
      if (current_user.platform_admin? || current_user.admin? || current_user.super_admin?) && selected_company_id.present? && selected_company_id > 0
        @company = ::Company.find_by(id: selected_company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [SettingsController] Platform admin selected invalid company ID: #{selected_company_id}"
          render json: { 
            error: 'Selected company not found',
            message: 'The selected company could not be found.'
          }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [SettingsController] Platform admin #{current_user.email} selected company: #{@company.name} (ID: #{@company.id})"
      else
        unless current_user
          Rails.logger.error "🚫 [SettingsController] No authenticated user found"
          render json: { 
            error: 'Authentication required',
            message: 'You must be logged in to access company settings'
          }, status: :unauthorized
          return
        end
        
        unless current_user.company_id.present?
          Rails.logger.error "🚫 [SettingsController] User #{current_user.id} has no company_id"
          render json: { 
            error: 'No company assigned',
            message: 'Your account is not associated with a company. Please contact support.'
          }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: current_user.company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [SettingsController] Company #{current_user.company_id} not found for user #{current_user.id}"
          render json: { 
            error: 'Company not found',
            message: 'The company associated with your account could not be found. Please contact support.'
          }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [SettingsController] Loaded company: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email} (ID: #{current_user.id})"
      end
    end

    # ============================================
    # Serializers
    # ============================================

    def serialize_tenant
      {
        id: @company.id.to_s,
        name: @company.name,
        domain: @company.try(:domain) || "#{@company.name.parameterize}.renterinsight.com",
        use_rbac_system: @company.use_rbac_system || false,
        settings: serialize_settings,
        branding: serialize_branding,
        customFields: serialize_custom_fields,
        createdAt: @company.created_at,
        updatedAt: @company.updated_at
      }
    end

    # Minimal tenant info for all authenticated users (no sensitive settings)
    def serialize_tenant_basic
      # Get subscription data using module access service
      module_access = @company.module_access
      subscription_status = module_access.subscription_status
      
      {
        id: @company.id.to_s,
        name: @company.name,
        domain: @company.try(:domain) || "#{@company.name.parameterize}.renterinsight.com",
        use_rbac_system: @company.use_rbac_system || false,
        settings: serialize_basic_settings,
        branding: serialize_branding,
        customFields: [],  # Don't expose custom fields to non-admin users
        createdAt: @company.created_at,
        updatedAt: @company.updated_at,
        # Subscription and module access data
        enabled_modules: module_access.enabled_modules,
        module_configs: module_access.module_configs,
        subscription_status: subscription_status[:status],
        plan_name: subscription_status[:plan_name],
        plan_display_name: subscription_status[:plan_display_name],
        is_active: subscription_status[:is_active],
        is_trial: subscription_status[:is_trial],
        trial_days_remaining: subscription_status[:trial_days_remaining],
        in_grace_period: subscription_status[:in_grace_period],
        max_users: subscription_status.dig(:limits, :max_users),
        max_locations: subscription_status.dig(:limits, :max_locations),
        max_storage_gb: subscription_status.dig(:limits, :max_storage_gb),
        # Public Inventory fields
        public_inventory_enabled: @company.public_inventory_enabled || false,
        public_inventory_token: @company.public_inventory_token
      }
    end

    # Basic settings that all users need (timezone, date format, etc.)
    def serialize_basic_settings
      base_settings = {
        timezone: 'America/New_York',
        currency: 'USD',
        dateFormat: 'MM/dd/yyyy',
        features: {
          workflowAutomation: true
        }
      }

      platform_general = Setting.get('Platform', 0, 'general', {})
      base_settings[:platformName] = platform_general['platformName'] || platform_general[:platformName] || ''

      if @company.operational_settings.present?
        operational = @company.operational_settings.deep_symbolize_keys
        base_settings[:timezone] = operational[:timezone] if operational[:timezone].present?
      end

      # Include pipeline stages so deal pipeline/form work without full settings permission
      pipeline_stages = Setting.get('Company', @company.id, 'pipeline_stages', nil)
      base_settings[:pipeline_stages] = pipeline_stages if pipeline_stages.present?

      base_settings
    end

    def serialize_settings
      # Start with hardcoded defaults
      base_settings = {
        timezone: 'America/New_York',
        currency: 'USD',
        dateFormat: 'MM/dd/yyyy',
        businessHours: default_business_hours,
        features: {
          workflowAutomation: true
        }
      }
      
      # Track sources for nested settings (communications.email, communications.sms, etc.)
      sources = {}

      # Layer 1: Load ALL platform-level settings (communications, operational, integrations, etc.)
      platform_settings = Setting.where(scope_type: 'Platform', scope_id: 0)
        .where.not(key: ['branding', 'quotes'])
        .pluck(:key, :value)
        .to_h

      platform_settings.each do |key, value|
        begin
          parsed_value = JSON.parse(value)
          base_settings[key.to_sym] = parsed_value
          
          # Track source for nested keys (e.g., communications.email, communications.sms)
          if parsed_value.is_a?(Hash)
            sources[key.to_sym] ||= {}
            parsed_value.keys.each do |nested_key|
              sources[key.to_sym][nested_key.to_sym] = 'platform'
            end
          end
          
          Rails.logger.info "📋 [serialize_settings] Loaded platform #{key}: #{parsed_value.inspect}"
        rescue JSON::ParserError
          base_settings[key.to_sym] = value
        end
      end

      # Extract platformName from platform general settings
      platform_general = Setting.get('Platform', 0, 'general', {})
      base_settings[:platformName] = platform_general['platformName'] || platform_general[:platformName] || ''

      # Layer 2: Merge company operational settings (legacy field-based approach)
      if @company.operational_settings.present?
        operational = @company.operational_settings.deep_symbolize_keys
        base_settings[:timezone] = operational[:timezone] if operational[:timezone].present?
        base_settings[:businessHours] = operational[:business_hours] if operational[:business_hours].present?
        base_settings[:deliveryRadiusMiles] = operational[:delivery_radius_miles] if operational[:delivery_radius_miles].present?
        base_settings[:allowWeekendDelivery] = operational[:allow_weekend_delivery] if operational.key?(:allow_weekend_delivery)
        base_settings[:requireAppointment] = operational[:require_appointment] if operational.key?(:require_appointment)
      end

      # Layer 3: Merge company-level settings (overrides platform)
      company_settings = Setting.where(scope_type: 'Company', scope_id: @company.id)
        .where.not(key: ['branding', 'quotes'])
        .pluck(:key, :value)
        .to_h

      company_settings.each do |key, value|
        begin
          parsed_value = JSON.parse(value)
          base_settings[key.to_sym] = parsed_value
          
          # Update source tracking for company overrides
          if parsed_value.is_a?(Hash)
            sources[key.to_sym] ||= {}
            parsed_value.keys.each do |nested_key|
              sources[key.to_sym][nested_key.to_sym] = 'company'
            end
          end
          
          Rails.logger.info "🏢 [serialize_settings] Company override for #{key}: #{parsed_value.inspect}"
        rescue JSON::ParserError
          base_settings[key.to_sym] = value
        end
      end

      # Layer 4: Add quotes settings (company-level) - ALWAYS include, even if empty
      quotes_setting = Setting.get('Company', @company.id, 'quotes', {})
      base_settings[:quotes] = quotes_setting.is_a?(Hash) ? quotes_setting.deep_symbolize_keys : {}

      # Layer 5: Location-level settings (highest priority - overrides company)
      if Current.location_id.present?
        location_settings = Setting.where(scope_type: 'Location', scope_id: Current.location_id)
          .where.not(key: ['branding', 'quotes'])
          .pluck(:key, :value)
          .to_h

        location_settings.each do |key, value|
          begin
            parsed_value = JSON.parse(value)
            base_settings[key.to_sym] = parsed_value
            
            # Update source tracking for location overrides
            if parsed_value.is_a?(Hash)
              sources[key.to_sym] ||= {}
              parsed_value.keys.each do |nested_key|
                sources[key.to_sym][nested_key.to_sym] = 'location'
              end
            end
            
            Rails.logger.info "📍 [serialize_settings] Location override for #{key}: #{parsed_value.inspect}"
          rescue JSON::ParserError
            base_settings[key.to_sym] = value
          end
        end
      end
      
      # Add _sources metadata to nested settings
      Rails.logger.info "🔍 [serialize_settings] Sources hash: #{sources.inspect}"
      sources.each do |key, nested_sources|
        if base_settings[key].is_a?(Hash)
          base_settings[key][:_sources] = nested_sources
          Rails.logger.info "✅ [serialize_settings] Added _sources to #{key}: #{nested_sources.inspect}"
        else
          Rails.logger.info "⚠️ [serialize_settings] Skipped _sources for #{key} (not a Hash)"
        end
      end

      Rails.logger.info "🎯 [serialize_settings] Final settings keys: #{base_settings.keys}"
      if base_settings[:communications].is_a?(Hash)
        Rails.logger.info "📡 [serialize_settings] communications._sources: #{base_settings[:communications][:_sources].inspect}"
      end

      base_settings
    end

    def serialize_branding
      platform_branding_raw = Setting.get('Platform', 0, 'branding', {})
      platform_branding = platform_branding_raw.deep_symbolize_keys
      
      Rails.logger.info "🎨 [serialize_branding] Platform branding: #{platform_branding.inspect}"
      
      default_branding = {
        primaryColor: '#3b82f6',
        secondaryColor: '#64748b',
        fontFamily: 'Inter'
      }

      # Waterfall: Platform → Company → Location
      merged_branding = default_branding.merge(platform_branding)
      
      if @company.present?
        company_branding_raw = Setting.get('Company', @company.id, 'branding', {})
        company_branding = company_branding_raw.deep_symbolize_keys
        
        Rails.logger.info "🎨 [serialize_branding] Company branding raw: #{company_branding_raw.inspect}"
        Rails.logger.info "🎨 [serialize_branding] Company branding symbolized: #{company_branding.inspect}"
        
        # Normalize company branding: faviconUrl → favicon BEFORE merging
        if company_branding[:faviconUrl].present?
          company_branding[:favicon] = company_branding[:faviconUrl]
          Rails.logger.info "🎨 [serialize_branding] Normalized company favicon: #{company_branding[:favicon]}"
        end
        
        merged_branding = merged_branding.merge(company_branding)
        
        Rails.logger.info "🎨 [serialize_branding] After company merge: #{merged_branding.inspect}"
        
        # Location-level branding (highest priority)
        if Current.location_id.present?
          location_branding_raw = Setting.get('Location', Current.location_id, 'branding', {})
          location_branding = location_branding_raw.deep_symbolize_keys
          
          # Normalize location branding: faviconUrl → favicon BEFORE merging
          if location_branding[:faviconUrl].present?
            location_branding[:favicon] = location_branding[:faviconUrl]
          end
          
          merged_branding = merged_branding.merge(location_branding) if location_branding.present?
          
          Rails.logger.info "🎨 [serialize_branding] After location merge: #{merged_branding.inspect}"
        end
      end
      
      if merged_branding[:logo].present?
        merged_branding[:logo] = absolute_url(merged_branding[:logo])
      end
      
      if merged_branding[:favicon].present?
        merged_branding[:favicon] = absolute_url(merged_branding[:favicon])
        merged_branding[:faviconUrl] = merged_branding[:favicon]
      end
      
      if merged_branding[:portalLogo].present?
        merged_branding[:portalLogo] = absolute_url(merged_branding[:portalLogo])
      end
      
      if platform_branding[:logo].present?
        merged_branding[:platformLogo] = absolute_url(platform_branding[:logo])
      end
      
      merged_branding
    end

    def serialize_custom_fields
      return [] unless @company.respond_to?(:custom_fields)
      @company.custom_fields.ordered.as_json
    rescue
      []
    end

    def default_business_hours
      {
        monday: { open: '09:00', close: '18:00', closed: false },
        tuesday: { open: '09:00', close: '18:00', closed: false },
        wednesday: { open: '09:00', close: '18:00', closed: false },
        thursday: { open: '09:00', close: '18:00', closed: false },
        friday: { open: '09:00', close: '18:00', closed: false },
        saturday: { open: '09:00', close: '17:00', closed: false },
        sunday: { open: '12:00', close: '17:00', closed: false }
      }
    end
  end
end
