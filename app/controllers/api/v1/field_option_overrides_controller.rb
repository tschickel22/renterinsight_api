# frozen_string_literal: true

module Api
  module V1
    class FieldOptionOverridesController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/field_option_overrides?module_name=inventory
      def index
        return unless authorize_action!('company_settings', 'read')

        overrides = @company.field_option_overrides
        overrides = overrides.for_module(params[:module_name]) if params[:module_name].present?

        render json: {
          overrides: overrides.map { |o| override_json(o) }
        }
      end

      # PUT /api/v1/field_option_overrides
      # Upsert: creates or updates an override for a specific field
      def upsert
        return unless authorize_action!('company_settings', 'update')

        override = @company.field_option_overrides.find_or_initialize_by(
          module_name: params[:module_name],
          field_key: params[:field_key]
        )

        options = params[:options]
        if options.is_a?(ActionController::Parameters)
          options = options.to_unsafe_h.values
        elsif options.is_a?(Array)
          options = options.map(&:to_s)
        end

        override.options = options

        if override.save
          render json: { override: override_json(override) }
        else
          render json: { error: override.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/field_option_overrides
      # Resets a field back to default options (removes override)
      def destroy
        return unless authorize_action!('company_settings', 'update')

        override = @company.field_option_overrides.find_by(
          module_name: params[:module_name],
          field_key: params[:field_key]
        )

        if override
          override.destroy
          render json: { message: 'Reset to default options' }
        else
          render json: { message: 'No override found (already using defaults)' }
        end
      end

      private

      def override_json(o)
        {
          id: o.id,
          module_name: o.module_name,
          field_key: o.field_key,
          options: o.options,
          updated_at: o.updated_at&.iso8601
        }
      end
    end
  end
end
