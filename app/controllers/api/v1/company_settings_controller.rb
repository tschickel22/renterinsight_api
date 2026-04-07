# frozen_string_literal: true

module Api
  module V1
    class CompanySettingsController < ApplicationController
      before_action :set_company_scope
      
      # RBAC Authorization - map to appropriate resources
      before_action :authorize_settings_read!, only: [:show_operational, :show_communication]
      before_action :authorize_settings_update!, only: [:update_operational, :update_communication, :update_rbac, :save_communication_settings, :clear_communication_settings]
      before_action :authorize_branding_read!, only: [:show_branding]
      before_action :authorize_branding_update!, only: [:update_branding]
      before_action :authorize_finance_manage!, only: [:show_loan, :update_loan]
      before_action :authorize_settings_update!, only: [:show_portal_modules, :update_portal_modules]
      before_action :authorize_settings_read!, only: [:show_form_states]
      before_action :authorize_settings_update!, only: [:update_form_states]

      # GET /api/v1/company_settings/operational
      def show_operational
        # Get operational settings from Settings table (Company -> Platform fallback)
        company_settings = Setting.get('Company', @company.id, 'operational_settings') || {}
        platform_defaults = PlatformDefaults.operational_settings

        render json: {
          operational_settings: company_settings,
          defaults: platform_defaults
        }
      end

      # PATCH /api/v1/company_settings/operational
      def update_operational
        Rails.logger.info "🔧 [CompanySettings#update_operational] Received params: #{params.inspect}"
        Rails.logger.info "🔧 [CompanySettings#update_operational] Company: #{@company&.name} (ID: #{@company&.id})"

        # Get operational_settings and convert to hash (permit all nested keys)
        operational_params = params[:operational_settings]
        if operational_params.present?
          # Use to_unsafe_h to convert ActionController::Parameters to hash
          settings = operational_params.to_unsafe_h
        else
          settings = {}
        end
        
        Rails.logger.info "📊 [CompanySettings#update_operational] Operational settings to save: #{settings.inspect}"

        # Save to Settings table: Setting.set(scope_type, scope_id, key, value)
        Setting.set('Company', @company.id, 'operational_settings', settings)
        
        # Retrieve saved settings to confirm
        saved_settings = Setting.get('Company', @company.id, 'operational_settings')
        Rails.logger.info "✅ [CompanySettings#update_operational] Settings saved successfully: #{saved_settings.inspect}"

        render json: {
          operational_settings: saved_settings,
          message: 'Operational settings updated successfully'
        }
      rescue => e
        Rails.logger.error "❌ [CompanySettings#update_operational] Error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # GET /api/v1/company_settings/branding
      def show_branding
      # Get company branding from Settings table (Company -> Platform fallback)
      company_branding = Setting.get('Company', @company.id, 'branding') || {}
      platform_defaults = Setting.get('Platform', 0, 'branding') || {}

      render json: {
      branding_settings: company_branding,
      defaults: platform_defaults
      }
      end

      # PATCH /api/v1/company_settings/branding
      def update_branding
      Rails.logger.info "🎨 [CompanySettings#update_branding] Received params: #{params.inspect}"
      Rails.logger.info "🎨 [CompanySettings#update_branding] Company: #{@company.name} (ID: #{@company.id})"
      
      # Get branding_settings and convert to hash (permit all nested keys)
      branding_params = params[:branding_settings]
    if branding_params.present?
        # Use to_unsafe_h to convert ActionController::Parameters to hash
        settings = branding_params.to_unsafe_h
      else
      settings = {}
      end
      
      Rails.logger.info "🎨 [CompanySettings#update_branding] Branding settings to save: #{settings.inspect}"

    # Clean up empty color strings - convert to nil
      cleaned_settings = settings.deep_dup
      ['primaryColor', 'secondaryColor', 'sideMenuColor'].each do |color_key|
        if cleaned_settings[color_key].present? && cleaned_settings[color_key].to_s.strip.empty?
          cleaned_settings[color_key] = nil
        end
      end
    Rails.logger.info "✨ [CompanySettings#update_branding] Cleaned settings: #{cleaned_settings.inspect}"

      # Save to Settings table: Setting.set(scope_type, scope_id, key, value)
      Setting.set('Company', @company.id, 'branding', cleaned_settings)
      
        # Retrieve saved settings to confirm
      saved_settings = Setting.get('Company', @company.id, 'branding')
      Rails.logger.info "✅ [CompanySettings#update_branding] Settings saved successfully: #{saved_settings.inspect}"

      render json: {
        branding_settings: saved_settings,
          message: 'Branding settings updated successfully'
    }
  rescue => e
    Rails.logger.error "❌ [CompanySettings#update_branding] Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: {
      errors: [e.message]
    }, status: :unprocessable_entity
  end

      # GET /api/v1/company_settings/communication
      def show_communication
        settings = @company.communications_settings || {}

        render json: {
          communication_settings: settings,
          defaults: PlatformDefaults.communication_settings
        }
      end

      # PATCH /api/v1/company_settings/communication
      def update_communication
        settings = params[:communication_settings] || {}

        @company.communications_settings = settings

        if @company.save
          render json: {
            communication_settings: @company.communications_settings,
            message: 'Communication settings updated successfully'
          }
        else
          render json: {
            errors: @company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating communication settings: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # PATCH /api/v1/company_settings/rbac
      def update_rbac
        Rails.logger.info "🔐 [CompanySettings#update_rbac] Received params: #{params.inspect}"

        use_rbac = params[:use_rbac_system]

        if use_rbac.nil?
          render json: { error: 'use_rbac_system parameter is required' }, status: :bad_request
          return
        end

        @company.use_rbac_system = ActiveModel::Type::Boolean.new.cast(use_rbac)

        if @company.save
          Rails.logger.info "✅ [CompanySettings#update_rbac] RBAC #{@company.use_rbac_system ? 'enabled' : 'disabled'} for company #{@company.name}"
          render json: {
            use_rbac_system: @company.use_rbac_system,
            message: "RBAC system #{@company.use_rbac_system ? 'enabled' : 'disabled'} successfully"
          }
        else
          Rails.logger.error "❌ [CompanySettings#update_rbac] Failed to update: #{@company.errors.full_messages}"
          render json: {
            errors: @company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating RBAC setting: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # GET /api/v1/company_settings/portal_modules
      def show_portal_modules
        settings = Setting.get('Company', @company.id, 'portal_modules', {})
        
        # Default settings if none saved
        default_settings = {
          'dashboard' => true,
          'loanManagement' => true,
          'invoices' => true,
          'quotes' => true,
          'documents' => true,
          'agreementSigning' => true,
          'financeApplications' => true,
          'serviceRequests' => false,
          'configurator' => false,
          'settings' => true
        }
        
        # Merge defaults with saved settings
        merged_settings = default_settings.merge(settings.stringify_keys)
        
        Rails.logger.info "🔧 [CompanySettings#show_portal_modules] Portal modules for company #{@company.id}: #{merged_settings.inspect}"
        
        render json: {
          portal_modules: merged_settings,
          defaults: default_settings
        }
      end

      # PATCH /api/v1/company_settings/portal_modules
      def update_portal_modules
        Rails.logger.info "🔧 [CompanySettings#update_portal_modules] Received params: #{params.inspect}"
        Rails.logger.info "🔧 [CompanySettings#update_portal_modules] Company: #{@company&.name} (ID: #{@company&.id})"

        settings = params[:portal_modules] || {}
        
        # Convert ActionController::Parameters to hash if needed
        settings = settings.to_unsafe_h if settings.respond_to?(:to_unsafe_h)
        
        Rails.logger.info "📊 [CompanySettings#update_portal_modules] Portal modules to save: #{settings.inspect}"

        # Save to Settings table
        Setting.set('Company', @company.id, 'portal_modules', settings)
        
        # Retrieve saved settings to confirm
        saved_settings = Setting.get('Company', @company.id, 'portal_modules', {})
        Rails.logger.info "✅ [CompanySettings#update_portal_modules] Settings saved successfully: #{saved_settings.inspect}"

        render json: {
          portal_modules: saved_settings,
          message: 'Portal module settings updated successfully'
        }
      rescue => e
        Rails.logger.error "❌ [CompanySettings#update_portal_modules] Error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # GET /api/v1/company_settings/form_states
      # Returns the states this company operates in (for filtering platform form templates)
      def show_form_states
        # Get allowed states from company column
        allowed = @company.allowed_form_states || []

        # Auto-detect from company and location addresses
        auto_detected = []
        auto_detected << @company.state if @company.state.present?
        @company.locations.where(is_deleted: [false, nil]).each do |loc|
          auto_detected << loc.state if loc.state.present?
        end
        auto_detected = auto_detected.compact.map(&:upcase).uniq.sort

        # Check current location override
        current_location_states = []
        current_location_name = nil
        if Current.location_id.present?
          loc = @company.locations.find_by(id: Current.location_id)
          if loc
            current_location_states = loc.respond_to?(:allowed_form_states) ? (loc.allowed_form_states || []) : []
            current_location_name = loc.name
          end
        end

        # Effective states follow the resolution chain
        effective = current_location_states.any? ? current_location_states :
                    allowed.any? ? allowed : auto_detected

        # State-level tax rates
        state_tax_rates = @company.respond_to?(:state_tax_rates) ? (@company.state_tax_rates || {}) : {}

        # Default sales tax rate (fallback when no state match)
        loan_settings = @company.loan_settings || {}
        default_sales_tax_rate = loan_settings['default_sales_tax_rate'] || loan_settings[:default_sales_tax_rate] || 0.0

        render json: {
          allowed_form_states: allowed,
          auto_detected_states: auto_detected,
          using_auto_detect: allowed.empty? && current_location_states.empty?,
          effective_states: effective,
          current_location_states: current_location_states,
          current_location_name: current_location_name,
          state_tax_rates: state_tax_rates,
          default_sales_tax_rate: default_sales_tax_rate
        }
      end

      # PATCH /api/v1/company_settings/form_states
      def update_form_states
        states = params[:allowed_form_states]
        unless states.is_a?(Array)
          return render json: { error: 'allowed_form_states must be an array' }, status: :unprocessable_entity
        end

        # Validate and normalize: uppercase 2-letter codes only
        cleaned = states.map { |s| s.to_s.strip.upcase }.select { |s| s.match?(/\A[A-Z]{2}\z/) }.uniq.sort

        updates = { allowed_form_states: cleaned }

        # Handle state_tax_rates if provided
        if params[:state_tax_rates].present?
          tax_rates = {}
          params[:state_tax_rates].to_unsafe_h.each do |state_code, rate|
            code = state_code.to_s.strip.upcase
            next unless code.match?(/\A[A-Z]{2}\z/)
            tax_rates[code] = rate.to_f
          end
          # Only keep rates for selected states
          tax_rates = tax_rates.select { |k, _| cleaned.include?(k) }
          updates[:state_tax_rates] = tax_rates
        end

        # Handle default_sales_tax_rate if provided
        if params.key?(:default_sales_tax_rate)
          loan_settings = @company.loan_settings || {}
          loan_settings['default_sales_tax_rate'] = params[:default_sales_tax_rate].to_f
          updates[:loan_settings] = loan_settings
        end

        @company.update!(updates)

        render json: {
          allowed_form_states: @company.allowed_form_states,
          state_tax_rates: @company.respond_to?(:state_tax_rates) ? (@company.state_tax_rates || {}) : {},
          default_sales_tax_rate: (@company.loan_settings || {})['default_sales_tax_rate'] || 0.0,
          message: "Updated to #{cleaned.length} state(s): #{cleaned.join(', ')}"
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/company_settings/tax_rate_for_state?state=WV
      # Returns the effective tax rate for a given state code
      # Used by invoice/deal forms to auto-populate based on delivery address
      def tax_rate_for_state
        state_code = params[:state].to_s.strip.upcase

        if state_code.blank? || !state_code.match?(/\A[A-Z]{2}\z/)
          return render json: { error: 'Valid 2-letter state code required' }, status: :unprocessable_entity
        end

        state_tax_rates = @company.respond_to?(:state_tax_rates) ? (@company.state_tax_rates || {}) : {}
        loan_settings = @company.loan_settings || {}
        default_rate = loan_settings['default_sales_tax_rate'] || loan_settings[:default_sales_tax_rate] || 0.0

        # Look up state-specific rate, fall back to default
        rate = state_tax_rates[state_code] || default_rate

        render json: {
          state: state_code,
          tax_rate: rate.to_f,
          source: state_tax_rates.key?(state_code) ? 'state' : 'default'
        }
      end

      # GET /api/v1/company_settings/loan
      def show_loan
        settings = @company.loan_settings || {}

        render json: {
          loan_settings: settings,
          defaults: default_loan_settings,
          payments_enabled: @company.external_payments_id.present?
        }
      end

      # PATCH /api/v1/company_settings/loan
      def update_loan
        Rails.logger.info "💰 [CompanySettings#update_loan] Received params: #{params.inspect}"

        settings = params[:loan_settings] || {}
        Rails.logger.info "📊 [CompanySettings#update_loan] Loan settings: #{settings.inspect}"

        @company.loan_settings = settings

        if @company.save
          Rails.logger.info "✅ [CompanySettings#update_loan] Loan settings saved successfully"
          render json: {
            loan_settings: @company.loan_settings,
            message: 'Loan settings updated successfully'
          }
        else
          Rails.logger.error "❌ [CompanySettings#update_loan] Save failed: #{@company.errors.full_messages}"
          render json: {
            errors: @company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating loan settings: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # PATCH /api/v1/company_settings/save_communication_settings
      # Save communication settings for THIS COMPANY (with correct scope_id)
      def save_communication_settings
        settings = params[:communication_settings] || params[:settings] || {}
        
        # Convert ActionController::Parameters to hash if needed
        settings = settings.to_unsafe_h if settings.respond_to?(:to_unsafe_h)
        
        Rails.logger.info "[Company Settings] 💾 Saving communications settings for company #{@company.id} (#{@company.name})"
        Rails.logger.info "[Company Settings] Settings keys: #{settings.keys.join(', ')}"
        
        # CRITICAL: Save with THIS company's ID as scope_id
        Setting.set('Company', @company.id, 'communications', settings)
        
        # Verify it was saved correctly
        saved = Setting.get('Company', @company.id, 'communications')
        Rails.logger.info "[Company Settings] ✅ Verified saved for company #{@company.id}: #{saved.present?}"
        
        render json: { 
          success: true, 
          message: 'Communication settings updated successfully',
          settings: saved
        }
      rescue => e
        Rails.logger.error "[Company Settings] ❌ Error saving settings: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/company_settings/clear_communication_settings
      # Clear all communication settings for this company and use platform defaults
      def clear_communication_settings
        # Delete the settings record entirely
        Setting.where(
          scope_type: 'Company',
          scope_id: @company.id,
          key: 'communications'
        ).destroy_all
        
        Rails.logger.info "[Company Settings] Cleared communications settings for company #{@company.id} (#{@company.name})"
        Rails.logger.info "[Company Settings] Now using platform defaults"
        
        render json: { 
          success: true, 
          message: 'Settings cleared successfully - now using platform defaults',
          parent_source: 'platform'
        }
      rescue => e
        Rails.logger.error "[Company Settings] Error clearing settings: #{e.message}"
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # RBAC Authorization Methods for company_settings resource
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

      # RBAC Authorization Methods for branding resource
      def authorize_branding_read!
        return if skip_rbac?
        unless current_user.has_permission?('branding', 'read', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied READ access to branding for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to view branding settings' }, status: :forbidden
        end
      end

      def authorize_branding_update!
        return if skip_rbac?
        unless current_user.has_permission?('branding', 'update', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied UPDATE access to branding for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to modify branding settings' }, status: :forbidden
        end
      end

      # RBAC Authorization Methods for finance resource
      def authorize_finance_manage!
        return if skip_rbac?
        unless current_user.has_permission?('finance', 'manage', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied MANAGE access to finance for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to manage finance settings' }, status: :forbidden
        end
      end

      # Skip RBAC for platform admins or if company doesn't use RBAC
      def skip_rbac?
        return true if current_user.platform_admin?
        return true if current_user.super_admin?
        return true unless @company&.use_rbac_system
        false
      end

      def set_company_scope
        unless current_user
          Rails.logger.error "[CompanySettingsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end

        company_id = current_company_id

        unless company_id.present?
          Rails.logger.error "[CompanySettingsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end

        @company = ::Company.find_by(id: company_id)

        if @company.nil?
          Rails.logger.error "[CompanySettingsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end

        Rails.logger.info "[CompanySettingsController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
      end

      # Default loan settings
      def default_loan_settings
        {
          default_interest_rate: 6.99,
          max_loan_term: 84,
          min_down_payment_percent: 10,
          default_payment_frequency: 'monthly',
          # Affordability Calculator defaults
          calculator_enabled: true,
          calculator_include_lot_rent: false,
          calculator_default_lot_rent: 500,
          calculator_include_property_tax: false,
          calculator_default_property_tax_rate: 1.0,
          calculator_include_insurance: false,
          calculator_default_insurance_annual: 1200,
          calculator_include_setup_fee: false,
          calculator_default_setup_fee: 0,
          calculator_loan_term_options: [120, 180, 240, 300, 360],
          calculator_disclaimer_text: 'This calculator provides estimates only. Actual rates, terms, and payments may vary based on credit qualification and lender requirements. Contact us for personalized financing options.',
          # Sales Tax
          default_sales_tax_rate: 0.0
        }
      end

      # GET /api/v1/company_settings/ai_settings
      def ai_settings
        unless current_user&.role == 'platform_admin'
          return render json: { error: 'Platform admin required' }, status: :forbidden
        end
        limit = begin
          Setting.get('Company', @company.id, 'ai_report_queries_monthly_limit', nil)
        rescue
          nil
        end
        platform_default = begin
          Setting.get('Platform', 0, 'ai_report_queries_monthly_limit', 100)
        rescue
          100
        end
        render json: { ai_report_queries_monthly_limit: limit&.to_i || platform_default.to_i }
      end

      # PATCH /api/v1/company_settings/ai_settings
      def update_ai_settings
        unless current_user&.role == 'platform_admin'
          return render json: { error: 'Platform admin required' }, status: :forbidden
        end
        limit = params[:ai_report_queries_monthly_limit].to_i
        Setting.set('Company', @company.id, 'ai_report_queries_monthly_limit', limit.to_s)
        render json: { ai_report_queries_monthly_limit: limit, message: 'AI settings saved' }
      end
    end
  end
end
