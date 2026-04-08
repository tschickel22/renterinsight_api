# frozen_string_literal: true

require 'csv'

module Api
  module V1
    class ImportExportMetadataController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/import_export/modules
      def modules
        return unless authorize_action!('data_import_export', 'read')
        render json: { modules: ImportExport::ModuleRegistry.available_modules }
      end

      # GET /api/v1/import_export/modules/:module_type/fields
      def fields
        return unless authorize_action!('data_import_export', 'read')

        cfg = ImportExport::ModuleRegistry.config_for(params[:module_type])
        return render json: { error: 'Unknown module' }, status: :not_found unless cfg

        fields = ImportExport::ModuleRegistry.fields_for(params[:module_type], company_id: @company.id)
        render json: {
          module_type: params[:module_type],
          label: cfg[:label],
          match_fields: cfg[:match_fields],
          supports_images: ImportExport::ModuleRegistry.supports_images?(params[:module_type]),
          fields: fields
        }
      end

      # GET /api/v1/import_export/modules/:module_type/sample_csv
      def sample_csv
        return unless authorize_action!('data_import_export', 'read')

        cfg = ImportExport::ModuleRegistry.config_for(params[:module_type])
        return render json: { error: 'Unknown module' }, status: :not_found unless cfg

        fields = ImportExport::ModuleRegistry.fields_for(params[:module_type], company_id: @company.id)
        csv_data = CSV.generate do |csv|
          csv << fields.map { |f| f[:required] ? "#{f[:label]} *" : f[:label] }
          csv << fields.map { |_| '' }
        end

        send_data csv_data,
                  type: 'text/csv',
                  filename: "#{params[:module_type]}_template.csv"
      end
    end
  end
end
