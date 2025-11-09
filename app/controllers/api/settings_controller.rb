# frozen_string_literal: true

module Api
  class SettingsController < ApplicationController
    # Skip authentication for tenant endpoint (branding is public info)
    skip_before_action :authenticate, only: [:tenant]
    before_action :set_company

    # GET /api/settings/tenant
    def tenant
      render json: {
        tenant: serialize_tenant
      }
    end

    # PATCH /api/settings
    def update
      settings_params = params.require(:settings).permit!
      
      settings_params.each do |key, value|
        Setting.set('Company', @company.id, key, value)
      end

      render json: {
        tenant: serialize_tenant
      }
    end

    # PATCH /api/settings/branding
    def update_branding
      branding_params = params.require(:branding).permit(
        :primaryColor, :secondaryColor, :fontFamily, :logo,
        :sideMenuColor, :portalName, :portalLogo
      )

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

    def set_company
      @company = ::Company.first
    end

    def serialize_tenant
      {
        id: @company.id.to_s,
        name: @company.name,
        domain: @company.try(:domain) || "#{@company.name.parameterize}.renterinsight.com",
        settings: serialize_settings,
        branding: serialize_branding,
        customFields: serialize_custom_fields,
        createdAt: @company.created_at,
        updatedAt: @company.updated_at
      }
    end

    def serialize_settings
      base_settings = {
        timezone: 'America/New_York',
        currency: 'USD',
        dateFormat: 'MM/dd/yyyy',
        businessHours: default_business_hours,
        features: {
          workflowAutomation: true
        }
      }

      # Add Platform Name from Platform settings (for "Powered by" branding)
      platform_general = Setting.get('Platform', 0, 'general', {})
      base_settings[:platformName] = platform_general['platformName'] || platform_general[:platformName] || ''

      # Merge in custom settings
      custom_settings = Setting.where(scope_type: 'Company', scope_id: @company.id)
        .where.not(key: ['branding', 'quotes'])
        .pluck(:key, :value)
        .to_h

      custom_settings.each do |key, value|
        begin
          base_settings[key.to_sym] = JSON.parse(value)
        rescue JSON::ParserError
          base_settings[key.to_sym] = value
        end
      end

      # Add quotes settings
      quotes_setting = Setting.get('Company', @company.id, 'quotes', {})
      base_settings[:quotes] = quotes_setting.deep_symbolize_keys if quotes_setting.present?

      base_settings
    end

    def serialize_branding
      # Get company branding (highest priority)
      company_branding_raw = Setting.get('Company', @company.id, 'branding', {})
      
      # Get platform branding (fallback)
      platform_branding_raw = Setting.get('Platform', 0, 'branding', {})
      
      # Symbolize keys for easier access (Setting.get returns string keys)
      company_branding = company_branding_raw.deep_symbolize_keys
      platform_branding = platform_branding_raw.deep_symbolize_keys
      
      default_branding = {
        primaryColor: '#3b82f6',
        secondaryColor: '#64748b',
        fontFamily: 'Inter'
      }

      # Merge: defaults < platform < company (company takes highest priority)
      merged_branding = default_branding
        .merge(platform_branding)
        .merge(company_branding)
      
      # Convert logo URLs from relative to absolute
      if merged_branding[:logo].present?
        merged_branding[:logo] = absolute_url(merged_branding[:logo])
      end
      
      if merged_branding[:portalLogo].present?
        merged_branding[:portalLogo] = absolute_url(merged_branding[:portalLogo])
      end
      
      # Also include platformLogo separately for fallback in frontend
      if platform_branding[:logo].present? && company_branding[:logo].blank?
        merged_branding[:platformLogo] = absolute_url(platform_branding[:logo])
      end
      
      merged_branding
    end

    def absolute_url(path)
      return path if path.blank?
      return path if path.start_with?('http://', 'https://')
      
      # Get base URL from request or ENV
      base_url = if request.present?
        "#{request.protocol}#{request.host_with_port}"
      else
        ENV['RAILS_API_URL'] || 'https://localhost:3001'
      end
      
      "#{base_url}#{path}"
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
