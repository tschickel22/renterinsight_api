# frozen_string_literal: true

module Api
  module V1
    class ImportTemplatesController < ApplicationController
      before_action :set_company_scope
      before_action :set_template, only: %i[show update destroy]

      def index
        return unless authorize_action!('data_import_export', 'read')

        scope = ImportTemplate.where(company_id: [@company.id, nil])
        scope = scope.where(module_type: params[:module_type]) if params[:module_type].present?
        render json: { items: scope.order(:name).map { |t| serialize(t) } }
      end

      def show
        return unless authorize_action!('data_import_export', 'read')
        render json: serialize(@template)
      end

      def create
        return unless authorize_action!('data_import_export', 'create')

        tpl = ImportTemplate.create!(template_params.merge(company_id: @company.id))
        render json: serialize(tpl), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def update
        return unless authorize_action!('data_import_export', 'update')
        return render json: { error: 'Cannot edit platform default' }, status: :forbidden if @template.is_platform_default && @template.company_id.nil?

        @template.update!(template_params)
        render json: serialize(@template)
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def destroy
        return unless authorize_action!('data_import_export', 'delete')
        return render json: { error: 'Cannot delete platform default' }, status: :forbidden if @template.is_platform_default && @template.company_id.nil?

        @template.destroy!
        render json: { message: 'Deleted' }
      end

      private

      def set_template
        @template = ImportTemplate.where(company_id: [@company.id, nil]).find_by(id: params[:id])
        render json: { error: 'Not found' }, status: :not_found unless @template
      end

      def template_params
        permitted = params.require(:import_template).permit(
          :name, :description, :module_type, :duplicate_strategy,
          column_mapping: {}, duplicate_match_fields: [], options: {}
        )
        permitted
      end

      def serialize(t)
        {
          id: t.id,
          name: t.name,
          description: t.description,
          module_type: t.module_type,
          column_mapping: t.column_mapping,
          duplicate_strategy: t.duplicate_strategy,
          duplicate_match_fields: t.duplicate_match_fields,
          options: t.options,
          is_platform_default: t.is_platform_default,
          company_id: t.company_id
        }
      end
    end
  end
end
