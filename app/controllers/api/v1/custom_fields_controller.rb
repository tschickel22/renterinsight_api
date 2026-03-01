# frozen_string_literal: true

module Api
  module V1
    class CustomFieldsController < ApplicationController
      before_action :set_company_scope
      before_action :set_custom_field, only: [:update, :destroy, :migrations, :create_migrations]

      # GET /api/v1/custom_fields?module=leads
      def index
        return unless authorize_action!('company_settings', 'read')

        unless params[:module].present?
          render json: { error: 'module parameter is required' }, status: :bad_request
          return
        end

        fields = @company.custom_fields.active.for_module(params[:module]).ordered

        render json: {
          custom_fields: fields.map { |f| custom_field_json(f) },
          meta: { total: fields.size, module: params[:module] }
        }
      end

      # POST /api/v1/custom_fields
      def create
        return unless authorize_action!('company_settings', 'update')

        field = @company.custom_fields.new(custom_field_params)
        field.created_by_id = current_user&.id

        if field.save
          render json: { custom_field: custom_field_json(field) }, status: :created
        else
          render json: { error: 'Validation failed', details: field.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotUnique
        render json: { error: 'A custom field with this name already exists for this module' }, status: :unprocessable_entity
      end

      # PATCH /api/v1/custom_fields/:id
      def update
        return unless authorize_action!('company_settings', 'update')

        @custom_field.updated_by_id = current_user&.id

        if @custom_field.update(custom_field_params)
          render json: { custom_field: custom_field_json(@custom_field) }
        else
          render json: { error: 'Validation failed', details: @custom_field.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/custom_fields/:id
      def destroy
        return unless authorize_action!('company_settings', 'update')

        @custom_field.update!(is_active: false)
        render json: { message: 'Custom field deactivated' }
      end

      # GET /api/v1/custom_fields/migration_recommendations?label=X&field_type=Y
      def migration_recommendations
        return unless authorize_action!('company_settings', 'read')

        label = params[:label]
        field_type = params[:field_type]

        recommendations = CustomField.migration_recommendations(label, field_type)
        render json: { recommendations: recommendations }
      end

      # GET /api/v1/custom_fields/:id/migrations
      def migrations
        return unless authorize_action!('company_settings', 'read')

        migrations = @company.custom_field_migrations
          .where(source_custom_field: @custom_field)
          .includes(:source_custom_field, :target_custom_field)

        render json: {
          migrations: migrations.map { |m| migration_json(m) }
        }
      end

      # POST /api/v1/custom_fields/:id/migrations
      def create_migrations
        return unless authorize_action!('company_settings', 'update')

        unless @custom_field.module == 'leads'
          render json: { error: 'Migrations can only be set up for lead custom fields' }, status: :unprocessable_entity
          return
        end

        mappings = (params[:mappings] || []).map do |m|
          {
            target_module: m[:target_module],
            migration_type: m[:migration_type],
            target_custom_field_id: m[:target_custom_field_id]
          }
        end

        result = CustomFieldMigrationService.setup_migrations(@custom_field, mappings, @company)

        if result[:success]
          render json: {
            success: true,
            migrations: result[:migrations].map { |m| migration_json(m) }
          }, status: :created
        else
          render json: { success: false, errors: result[:errors] }, status: :unprocessable_entity
        end
      end

      private

      def set_custom_field
        @custom_field = @company.custom_fields.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Custom field not found' }, status: :not_found
      end

      def custom_field_params
        params.require(:custom_field).permit(
          :name, :label, :field_type, :module, :required, :display_order,
          :section, :description, :placeholder, :default_value, :visibility,
          options: [], validation_rules: {}
        )
      end

      def custom_field_json(field)
        {
          id: field.id,
          module: field.module,
          name: field.name,
          fieldKey: field.field_key,
          label: field.label,
          fieldType: field.field_type,
          required: field.required,
          defaultValue: field.default_value,
          displayOrder: field.display_order,
          section: field.section,
          description: field.description,
          placeholder: field.placeholder,
          isActive: field.is_active,
          isSystemField: field.is_system_field,
          hidden: field.respond_to?(:hidden) ? field.hidden : false,
          visibility: field.visibility || 'internal',
          options: field.options,
          validationRules: field.validation_rules,
          createdAt: field.created_at&.iso8601,
          updatedAt: field.updated_at&.iso8601
        }
      end

      def migration_json(m)
        {
          id: m.id,
          sourceCustomFieldId: m.source_custom_field_id,
          sourceFieldLabel: m.source_custom_field&.label,
          targetModule: m.target_module,
          targetCustomFieldId: m.target_custom_field_id,
          targetFieldLabel: m.target_custom_field&.label,
          targetFieldKey: m.target_custom_field&.field_key,
          migrationType: m.migration_type,
          createdAt: m.created_at&.iso8601,
          updatedAt: m.updated_at&.iso8601
        }
      end
    end
  end
end
