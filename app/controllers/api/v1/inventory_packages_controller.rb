# frozen_string_literal: true

module Api
  module V1
    class InventoryPackagesController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions: [:index],
        create_actions: [:create, :apply_template],
        update_actions: [:update, :reorder],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_vehicle
      before_action :set_package, only: [:update, :destroy]

      # GET /api/v1/vehicles/:vehicle_id/packages
      def index
        packages = @vehicle.inventory_packages.ordered
        render json: packages.map { |p| package_json(p) }
      end

      # POST /api/v1/vehicles/:vehicle_id/packages
      def create
        package = @vehicle.inventory_packages.build(package_params)
        package.position = @vehicle.inventory_packages.maximum(:position).to_i + 1

        if package.save
          render json: package_json(package), status: :created
        else
          render json: { errors: package.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/vehicles/:vehicle_id/packages/apply_template
      # Snapshot a company template onto this vehicle
      def apply_template
        template = @company.package_templates.find_by(id: params[:template_id])
        return render json: { error: 'Template not found' }, status: :not_found unless template

        attrs = template.to_inventory_package_attrs
        attrs[:position] = @vehicle.inventory_packages.maximum(:position).to_i + 1

        package = @vehicle.inventory_packages.build(attrs)

        if package.save
          render json: package_json(package), status: :created
        else
          render json: { errors: package.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/vehicles/:vehicle_id/packages/:id
      def update
        if @package.update(package_params)
          render json: package_json(@package)
        else
          render json: { errors: @package.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/vehicles/:vehicle_id/packages/:id
      def destroy
        @package.destroy
        head :no_content
      end

      # POST /api/v1/vehicles/:vehicle_id/packages/reorder
      def reorder
        ordered_ids = params[:ordered_ids] || []
        ordered_ids.each_with_index do |id, idx|
          @vehicle.inventory_packages.find_by(id: id)&.update_column(:position, idx)
        end
        render json: { success: true }
      end

      private

      def set_vehicle
        @vehicle = @company.vehicles.active.find_by(id: params[:vehicle_id])
        render json: { error: 'Vehicle not found' }, status: :not_found unless @vehicle
      end

      def set_package
        @package = @vehicle.inventory_packages.find_by(id: params[:id])
        render json: { error: 'Package not found' }, status: :not_found unless @package
      end

      def package_params
        # Frontend sends camelCase keys - transform to snake_case
        raw = params.require(:inventory_package).to_unsafe_h
        normalized = raw.transform_keys { |k| k.to_s.underscore }
        ActionController::Parameters.new(normalized).permit(
          :name, :description, :price, :include_in_total, :show_price_in_marketing, :position, :package_template_id
        )
      end

      def package_json(pkg)
        {
          id: pkg.id,
          vehicleId: pkg.vehicle_id,
          packageTemplateId: pkg.package_template_id,
          name: pkg.name,
          description: pkg.description,
          price: pkg.price&.to_f,
          includeInTotal: pkg.include_in_total,
          showPriceInMarketing: pkg.show_price_in_marketing,
          position: pkg.position,
          createdAt: pkg.created_at,
          updatedAt: pkg.updated_at
        }
      end
    end
  end
end
