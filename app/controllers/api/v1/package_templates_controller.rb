# frozen_string_literal: true

module Api
  module V1
    class PackageTemplatesController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions: [:index],
        create_actions: [:create],
        update_actions: [:update, :reorder],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_template, only: [:update, :destroy]

      # GET /api/v1/package_templates
      def index
        templates = @company.package_templates.active.ordered

        # Filter by vehicle type if provided (rv/mh) - also return 'all' templates
        if params[:vehicle_type].present?
          vt = params[:vehicle_type].downcase
          templates = templates.where(applicable_to: [vt, 'all'])
        end

        render json: templates.map { |t| template_json(t) }
      end

      # POST /api/v1/package_templates
      def create
        template = @company.package_templates.build(template_params)
        template.position = @company.package_templates.maximum(:position).to_i + 1

        if template.save
          render json: template_json(template), status: :created
        else
          render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/package_templates/:id
      def update
        if @template.update(template_params)
          render json: template_json(@template)
        else
          render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/package_templates/:id
      def destroy
        @template.update(is_active: false)
        head :no_content
      end

      # POST /api/v1/package_templates/reorder
      def reorder
        ordered_ids = params[:ordered_ids] || []
        ordered_ids.each_with_index do |id, idx|
          @company.package_templates.find_by(id: id)&.update_column(:position, idx)
        end
        render json: { success: true }
      end

      private

      def set_template
        @template = @company.package_templates.find_by(id: params[:id])
        render json: { error: 'Package template not found' }, status: :not_found unless @template
      end

      def template_params
        # Frontend sends camelCase keys - transform to snake_case
        raw = params.require(:package_template).to_unsafe_h
        normalized = raw.transform_keys { |k| k.to_s.underscore }
        ActionController::Parameters.new(normalized).permit(
          :name, :description, :default_price, :include_in_total, :is_active, :position, :applicable_to, :taxable, :tax_rate
        )
      end

      def template_json(template)
        {
          id: template.id,
          name: template.name,
          description: template.description,
          defaultPrice: template.default_price&.to_f,
          includeInTotal: template.include_in_total,
          position: template.position,
          isActive: template.is_active,
          applicableTo: template.applicable_to || 'all',
          taxable: template.respond_to?(:taxable) ? (template.taxable || false) : false,
          taxRate: template.respond_to?(:tax_rate) ? template.tax_rate&.to_f : nil,
          createdAt: template.created_at,
          updatedAt: template.updated_at
        }
      end
    end
  end
end
