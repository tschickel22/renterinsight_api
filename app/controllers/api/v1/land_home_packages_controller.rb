# frozen_string_literal: true

module Api
  module V1
    # Land + home packages: a lot and a home offered together at one price.
    # Managed from a parcel's page in Land Management; shown on the dealer's
    # website by Public::LandHomePackagesController.
    class LandHomePackagesController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions: [:index, :suggested_price],
        create_actions: [:create],
        update_actions: [:update],
        delete_actions: [:destroy]

      before_action :set_company
      before_action :set_package, only: [:update, :destroy]

      # GET /api/v1/land-home-packages?land_parcel_id=
      def index
        packages = @company.land_home_packages.includes(:land_parcel, :vehicle).ordered
        packages = packages.where(land_parcel_id: params[:land_parcel_id]) if params[:land_parcel_id].present?
        packages = packages.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id].present?

        render json: { packages: packages.map { |p| package_json(p) } }
      end

      # GET /api/v1/land-home-packages/suggested_price?land_parcel_id=&vehicle_id=
      def suggested_price
        parcel = @company.land_parcels.active.find(params[:land_parcel_id])
        vehicle = @company.vehicles.find(params[:vehicle_id])
        render json: { price: LandHomePackage.suggested_price(parcel, vehicle)&.to_f }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Lot or home not found' }, status: :not_found
      end

      # POST /api/v1/land-home-packages
      def create
        attrs = package_params
        # CRITICAL: both halves come from this company, never from params as given.
        parcel = @company.land_parcels.active.find_by(id: params.dig(:package, :land_parcel_id))
        vehicle = @company.vehicles.where(is_deleted: [false, nil]).find_by(id: params.dig(:package, :vehicle_id))
        return render json: { errors: ['Lot not found'] }, status: :unprocessable_entity unless parcel
        return render json: { errors: ['Home not found'] }, status: :unprocessable_entity unless vehicle

        package = @company.land_home_packages.new(attrs.merge(land_parcel: parcel, vehicle: vehicle))
        package.price = LandHomePackage.suggested_price(parcel, vehicle) unless attrs.key?(:price)
        package.position = parcel.land_home_packages.maximum(:position).to_i + 1

        if package.save
          render json: { package: package_json(package) }, status: :created
        else
          render json: { errors: package.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/land-home-packages/:id
      def update
        if @package.update(package_params)
          render json: { package: package_json(@package) }
        else
          render json: { errors: @package.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/land-home-packages/:id
      def destroy
        @package.destroy
        head :no_content
      end

      private

      def set_company
        return render json: { error: 'Authentication required' }, status: :unauthorized unless current_user

        @company = ::Company.find_by(id: current_company_id)
        render json: { error: 'Company not found' }, status: :not_found unless @company
      end

      def set_package
        @package = @company.land_home_packages.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Package not found' }, status: :not_found
      end

      # The lot and home are fixed once paired: change them by making another
      # package. NEVER permit company_id.
      def package_params
        params.require(:package).permit(:name, :price, :description, :show_on_website, :position)
      end

      def package_json(package)
        parcel = package.land_parcel
        vehicle = package.vehicle
        {
          id: package.id,
          name: package.name,
          display_name: package.display_name,
          price: package.price&.to_f,
          suggested_price: LandHomePackage.suggested_price(parcel, vehicle)&.to_f,
          description: package.description,
          show_on_website: package.show_on_website,
          position: package.position,
          land_parcel: {
            id: parcel.id,
            display_name: parcel.display_name,
            status: parcel.status,
            price: parcel.price&.to_f,
            acreage: parcel.acreage&.to_f,
            city: parcel.city,
            state: parcel.state,
          },
          vehicle: {
            id: vehicle.id,
            display_name: package.vehicle_name,
            stock_number: vehicle.stock_number,
            status: vehicle.status,
            is_deleted: vehicle.is_deleted,
            price: (vehicle.sale_price.presence || vehicle.msrp)&.to_f,
            bedrooms: vehicle.bedrooms,
            bathrooms: vehicle.bathrooms&.to_f,
            square_feet: vehicle.square_feet,
            image: first_image(vehicle.images),
          },
        }
      end

      def first_image(images)
        first = Array(images).first
        first.is_a?(Hash) ? (first['url'] || first[:url]) : first
      end
    end
  end
end
