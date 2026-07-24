# frozen_string_literal: true

module Api
  module V1
    # Read-only reference: the field names an external integration (Zapier/FB,
    # etc.) can map onto when POSTing to the partner API, per module — the
    # standard fields plus this company's dealer-defined custom fields. Powers
    # the "Export field map" action so an operator can hand exact keys to whoever
    # configures the Zap. Standard fields come from Integration::MappableFields,
    # the SAME source the partner controllers permit — so the export can never
    # drift from what the API actually accepts.
    class IntegrationFieldsController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/integration/field_map?module=leads
      def field_map
        return unless authorize_action!('company_settings', 'read')

        mod = params[:module].to_s
        unless Integration::MappableFields.supported?(mod)
          return render(json: { error: "Invalid module. One of: #{Integration::MappableFields.modules.join(', ')}" }, status: :bad_request)
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
          fields: Integration::MappableFields.field_map(mod).map { |f| f.merge(custom: false) },
          custom_fields: custom
        }
      end
    end
  end
end
