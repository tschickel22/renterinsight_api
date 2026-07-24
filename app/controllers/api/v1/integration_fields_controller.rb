# frozen_string_literal: true

module Api
  module V1
    # Read-only reference: the field names an external integration (Zapier/FB,
    # etc.) can map onto when POSTing to the partner API, per module — the
    # standard fields plus this company's dealer-defined custom fields. Powers
    # the "Export field map" action so an operator can hand exact keys to whoever
    # configures the Zap.
    class IntegrationFieldsController < ApplicationController
      before_action :set_company_scope

      # Standard partner-API fields per module (mirrors the *_params permit lists).
      # `note` documents accepted aliases the API also understands.
      STANDARD_FIELDS = {
        'leads' => [
          { key: 'first_name', label: 'First Name', note: 'or send full_name to auto-split into first/last' },
          { key: 'last_name',  label: 'Last Name' },
          { key: 'email',      label: 'Email', note: 'or email_address' },
          { key: 'phone',      label: 'Phone', note: 'or phone_number' },
          { key: 'status',     label: 'Status' },
          { key: 'source',     label: 'Source (name)' },
          { key: 'budget_range', label: 'Budget Range' },
          { key: 'purchase_timeframe', label: 'Purchase Timeframe' },
          { key: 'preferred_contact_method', label: 'Preferred Contact Method' },
          { key: 'interests_requirements', label: 'Interests / Requirements' },
          { key: 'rv_experience', label: 'RV Experience' },
          { key: 'notes', label: 'Notes' }
        ],
        'deals' => [
          { key: 'name', label: 'Deal Name' },
          { key: 'customer_name', label: 'Customer Name' },
          { key: 'value', label: 'Value' },
          { key: 'stage', label: 'Stage' },
          { key: 'deal_type', label: 'Deal Type' },
          { key: 'expected_close_date', label: 'Expected Close Date' },
          { key: 'delivery_date', label: 'Delivery Date' },
          { key: 'account_id', label: 'Account ID' },
          { key: 'contact_id', label: 'Contact ID' },
          { key: 'source_id', label: 'Source ID' },
          { key: 'description', label: 'Description' },
          { key: 'notes', label: 'Notes' }
        ],
        'accounts' => [
          { key: 'name', label: 'Account Name' },
          { key: 'account_type', label: 'Account Type' },
          { key: 'email', label: 'Email' },
          { key: 'phone', label: 'Phone' },
          { key: 'website', label: 'Website' },
          { key: 'industry', label: 'Industry' },
          { key: 'billing_street', label: 'Billing Street' },
          { key: 'billing_city', label: 'Billing City' },
          { key: 'billing_state', label: 'Billing State' },
          { key: 'billing_postal_code', label: 'Billing Postal Code' },
          { key: 'description', label: 'Description' },
          { key: 'notes', label: 'Notes' }
        ]
      }.freeze

      # GET /api/v1/integration/field_map?module=leads
      def field_map
        return unless authorize_action!('company_settings', 'read')

        mod = params[:module].to_s
        unless STANDARD_FIELDS.key?(mod)
          return render(json: { error: "Invalid module. One of: #{STANDARD_FIELDS.keys.join(', ')}" }, status: :bad_request)
        end

        # Custom fields are per-company. Platform admins managing a specific
        # company's keys pass company_id; otherwise scope to the caller's company.
        company_id = params[:company_id].presence || @company&.id
        custom =
          if company_id
            CustomField.active.for_module(mod).where(company_id: company_id).ordered.map do |f|
              { key: f.field_key, label: f.name, type: f.field_type, custom: true }
            end
          else
            []
          end

        render json: {
          module: mod,
          fields: STANDARD_FIELDS[mod].map { |f| f.merge(custom: false) },
          custom_fields: custom
        }
      end
    end
  end
end
