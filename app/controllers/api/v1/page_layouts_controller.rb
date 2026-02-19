# frozen_string_literal: true

module Api
  module V1
    class PageLayoutsController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/page_layouts/:module_name
      def show
        return unless authorize_action!('company_settings', 'read')

        layout = find_or_create_layout(params[:module_name])

        render json: {
          page_layout: page_layout_json(layout)
        }
      end

      # PATCH /api/v1/page_layouts/:module_name
      def update
        return unless authorize_action!('company_settings', 'update')

        layout = find_or_create_layout(params[:module_name])
        layout.updated_by_id = current_user&.id

        layout_data = params[:layout_data]
        if layout_data.is_a?(ActionController::Parameters)
          layout_data = layout_data.to_unsafe_h
        end

        # Enforce protected fields cannot be hidden
        protected_keys = PageLayout::PROTECTED_FIELDS[params[:module_name]] || []
        if protected_keys.any? && layout_data.present? && layout_data['sections'].is_a?(Array)
          layout_data['sections'].each do |section|
            next unless section['fields'].is_a?(Array)
            section['fields'].each do |field|
              if protected_keys.include?(field['key'])
                field['visible'] = true
              end
            end
          end
        end

        if layout.update(layout_data: layout_data)
          render json: { page_layout: page_layout_json(layout) }
        else
          render json: { error: 'Validation failed', details: layout.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/page_layouts/:module_name/reset
      def reset
        return unless authorize_action!('company_settings', 'update')

        layout = find_or_create_layout(params[:module_name])
        layout.updated_by_id = current_user&.id
        default_data = PageLayout.default_layout_for(params[:module_name])

        if layout.update(layout_data: default_data)
          render json: { page_layout: page_layout_json(layout), message: 'Layout reset to default' }
        else
          render json: { error: 'Reset failed', details: layout.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/page_layouts/:module_name/field_definitions
      def field_definitions
        return unless authorize_action!('company_settings', 'read')

        module_name = params[:module_name]
        standard = standard_field_definitions(module_name)
        custom = custom_field_definitions(module_name)

        render json: {
          field_definitions: standard + custom,
          meta: {
            module: module_name,
            standard_count: standard.size,
            custom_count: custom.size,
            total: standard.size + custom.size
          }
        }
      end

      private

      def find_or_create_layout(module_name)
        layout = @company.page_layouts.for_module(module_name).find_by(layout_type: 'detail')

        unless layout
          layout = @company.page_layouts.create!(
            module_name: module_name,
            layout_type: 'detail',
            layout_data: PageLayout.default_layout_for(module_name),
            is_default: true,
            created_by_id: current_user&.id
          )
        end

        layout
      end

      def page_layout_json(layout)
        {
          id: layout.id,
          moduleName: layout.module_name,
          layoutType: layout.layout_type,
          layoutData: layout.layout_data,
          isDefault: layout.is_default,
          createdAt: layout.created_at&.iso8601,
          updatedAt: layout.updated_at&.iso8601
        }
      end

      def standard_field_definitions(module_name)
        case module_name
        when 'leads'
          leads_standard_fields
        when 'accounts'
          accounts_standard_fields
        when 'contacts'
          contacts_standard_fields
        else
          []
        end
      end

      def accounts_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['accounts'] || []
        [
          { key: 'name', label: 'Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('name') },
          { key: 'email', label: 'Email', type: 'email', source: 'standard', required: false, protected: protected_keys.include?('email') },
          { key: 'phone', label: 'Phone', type: 'phone', source: 'standard', required: false, protected: protected_keys.include?('phone') },
          { key: 'account_type', label: 'Account Type', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[prospect customer partner vendor other] },
          { key: 'status', label: 'Status', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[active inactive suspended] },
          { key: 'rating', label: 'Rating', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[hot warm cold] },
          { key: 'website', label: 'Website', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'industry', label: 'Industry', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'ownership', label: 'Ownership', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'annual_revenue', label: 'Annual Revenue', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'employee_count', label: 'Employee Count', type: 'number', source: 'standard', required: false, protected: false },
          { key: 'source_id', label: 'Source', type: 'select', source: 'standard', required: false, protected: false,
            options: Source.for_company(@company.id).order(:name).pluck(:name) },
          { key: 'owner_id', label: 'Owner', type: 'user', source: 'standard', required: false, protected: false },
          { key: 'billing_street', label: 'Billing Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_city', label: 'Billing City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_state', label: 'Billing State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_postal_code', label: 'Billing Postal Code', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'billing_country', label: 'Billing Country', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_street', label: 'Shipping Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_city', label: 'Shipping City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_state', label: 'Shipping State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_postal_code', label: 'Shipping Postal Code', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'shipping_country', label: 'Shipping Country', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'description', label: 'Description', type: 'longtext', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false }
        ]
      end

      def contacts_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['contacts'] || []
        [
          { key: 'first_name', label: 'First Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('first_name') },
          { key: 'last_name', label: 'Last Name', type: 'text', source: 'standard', required: true, protected: protected_keys.include?('last_name') },
          { key: 'email', label: 'Email', type: 'email', source: 'standard', required: true, protected: protected_keys.include?('email') },
          { key: 'phone', label: 'Phone', type: 'phone', source: 'standard', required: false, protected: protected_keys.include?('phone') },
          { key: 'title', label: 'Job Title', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'department', label: 'Department', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'company_name', label: 'Company Name', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'account_id', label: 'Account', type: 'select', source: 'standard', required: false, protected: false },
          { key: 'owner_id', label: 'Owner', type: 'user', source: 'standard', required: false, protected: false },
          { key: 'is_primary', label: 'Primary Contact', type: 'boolean', source: 'standard', required: false, protected: false },
          { key: 'street', label: 'Street', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'city', label: 'City', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'state', label: 'State', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'zip', label: 'Zip', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'country', label: 'Country', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'opt_out_email', label: 'Opt Out Email', type: 'boolean', source: 'standard', required: false, protected: false },
          { key: 'opt_out_sms', label: 'Opt Out SMS', type: 'boolean', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false }
        ]
      end

      def leads_standard_fields
        protected_keys = PageLayout::PROTECTED_FIELDS['leads'] || []
        [
          { key: 'first_name', label: 'First Name', type: 'text', source: 'standard', required: true, protected: true },
          { key: 'last_name', label: 'Last Name', type: 'text', source: 'standard', required: true, protected: true },
          { key: 'email', label: 'Email', type: 'email', source: 'standard', required: true, protected: true },
          { key: 'phone', label: 'Phone', type: 'phone', source: 'standard', required: true, protected: true },
          { key: 'status', label: 'Status', type: 'select', source: 'standard', required: false, protected: false,
            options: %w[new contacted qualified proposal negotiation won lost] },
          { key: 'owner_id', label: 'Owner', type: 'user', source: 'standard', required: false, protected: false },
          { key: 'source_id', label: 'Source', type: 'select', source: 'standard', required: false, protected: false,
            options: Source.for_company(@company.id).order(:name).pluck(:name) },
          { key: 'budget_range', label: 'Budget Range', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'purchase_timeframe', label: 'Purchase Timeframe', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'rv_experience', label: 'RV Experience', type: 'text', source: 'standard', required: false, protected: false },
          { key: 'interests_requirements', label: 'Interests/Requirements', type: 'longtext', source: 'standard', required: false, protected: false },
          { key: 'notes', label: 'Notes', type: 'longtext', source: 'standard', required: false, protected: false }
        ]
      end

      def custom_field_definitions(module_name)
        @company.custom_fields.active.for_module(module_name).ordered.map do |field|
          {
            id: field.id,
            key: field.field_key,
            label: field.label || field.name,
            type: field.field_type,
            source: 'custom',
            required: field.required || false,
            protected: false,
            options: field.options,
            placeholder: field.placeholder
          }
        end
      end
    end
  end
end
