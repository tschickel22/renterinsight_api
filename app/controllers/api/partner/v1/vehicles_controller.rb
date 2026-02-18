# frozen_string_literal: true

module Api
  module Partner
    module V1
      class VehiclesController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :vehicle

        before_action :authorize_vehicles
        before_action :set_vehicle, only: [:show, :update, :destroy]

        # GET /api/partner/v1/vehicles
        def index
          vehicles = company_scope(Vehicle).where(is_deleted: false)

          # Filters
          vehicles = vehicles.where(status: params[:status]) if params[:status].present?
          vehicles = vehicles.where(listing_type: params[:listing_type]) if params[:listing_type].present?
          vehicles = vehicles.where(condition: params[:condition]) if params[:condition].present?
          vehicles = vehicles.where(year: params[:year]) if params[:year].present?
          vehicles = vehicles.where("LOWER(make) = ?", params[:make].downcase) if params[:make].present?
          vehicles = vehicles.where("LOWER(model) = ?", params[:model].downcase) if params[:model].present?
          vehicles = vehicles.where(location_id: params[:location_id]) if params[:location_id].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            vehicles = vehicles.where(
              "inventory_id ILIKE :q OR vin ILIKE :q OR serial_number ILIKE :q OR make ILIKE :q OR model ILIKE :q OR stock_number ILIKE :q",
              q: q
            )
          end

          # Cursor-based pagination
          vehicles = vehicles.order(:id)
          vehicles = vehicles.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          vehicles = vehicles.limit(limit + 1)

          records = vehicles.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |v| vehicle_json(v) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/vehicles/:id
        def show
          render json: { data: vehicle_json(@vehicle, detailed: true) }
        end

        # POST /api/partner/v1/vehicles
        def create
          vehicle = company_scope(Vehicle).new(vehicle_params)

          if vehicle.save
            render json: { data: vehicle_json(vehicle, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: vehicle.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/vehicles/:id
        def update
          if @vehicle.update(vehicle_params)
            render json: { data: vehicle_json(@vehicle, detailed: true) }
          else
            render json: { error: "Validation failed", details: @vehicle.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/vehicles/:id
        def destroy
          @vehicle.update!(is_deleted: true, deleted_at: Time.current)
          render json: { data: { id: @vehicle.id, deleted: true } }
        end

        private

        def authorize_vehicles
          case action_name
          when "index", "show"
            authorize_permission!(:vehicles, :read)
          when "create"
            authorize_permission!(:vehicles, :create)
          when "update"
            authorize_permission!(:vehicles, :update)
          when "destroy"
            authorize_permission!(:vehicles, :delete)
          end
        end

        def set_vehicle
          @vehicle = company_scope(Vehicle).where(is_deleted: false).find(params[:id])
        end

        def vehicle_params
          params.permit(
            :inventory_id, :stock_number, :vin, :serial_number,
            :year, :make, :model, :trim, :color, :condition, :status,
            :listing_type, :location_id,
            :cost, :sale_price, :rent_price, :rent_to_own_price, :msrp,
            :deposit_amount, :dealer_cost, :freight_cost, :total_cost,
            :minimum_price, :target_gross,
            :mileage, :description, :notes,
            :bedrooms, :bathrooms, :length, :width, :square_feet,
            :sleeps, :weight, :body_style, :fuel_type, :transmission,
            :rv_type, :rv_class, :slideouts, :awnings,
            :home_type, :dwelling_type, :foundation_type,
            :location_city, :location_state, :location_zip,
            :exterior_color, :interior_color,
            :photo_url, :video_url, :virtual_tour_url, :listing_url,
            :overlay_text, :special_features, :terms,
            features: [], appliances: []
          )
        end

        def vehicle_json(vehicle, detailed: false)
          json = {
            id: vehicle.id,
            inventory_id: vehicle.inventory_id,
            stock_number: vehicle.stock_number,
            vin: vehicle.vin,
            serial_number: vehicle.serial_number,
            year: vehicle.year,
            make: vehicle.make,
            model: vehicle.model,
            trim: vehicle.trim,
            condition: vehicle.condition,
            status: vehicle.status,
            listing_type: vehicle.listing_type,
            sale_price: vehicle.sale_price,
            location_id: vehicle.location_id,
            created_at: vehicle.created_at&.iso8601,
            updated_at: vehicle.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              color: vehicle.color,
              exterior_color: vehicle.exterior_color,
              interior_color: vehicle.interior_color,
              cost: vehicle.cost,
              rent_price: vehicle.rent_price,
              rent_to_own_price: vehicle.rent_to_own_price,
              msrp: vehicle.msrp,
              deposit_amount: vehicle.deposit_amount,
              dealer_cost: vehicle.dealer_cost,
              freight_cost: vehicle.freight_cost,
              total_cost: vehicle.total_cost,
              minimum_price: vehicle.minimum_price,
              target_gross: vehicle.target_gross,
              mileage: vehicle.mileage,
              description: vehicle.description,
              notes: vehicle.notes,
              features: vehicle.features,
              bedrooms: vehicle.bedrooms,
              bathrooms: vehicle.bathrooms,
              length: vehicle.length,
              width: vehicle.width,
              square_feet: vehicle.square_feet,
              sleeps: vehicle.sleeps,
              weight: vehicle.weight,
              body_style: vehicle.body_style,
              fuel_type: vehicle.fuel_type,
              transmission: vehicle.transmission,
              rv_type: vehicle.rv_type,
              rv_class: vehicle.rv_class,
              slideouts: vehicle.slideouts,
              awnings: vehicle.awnings,
              generator: vehicle.generator,
              engine_make: vehicle.engine_make,
              engine_type: vehicle.engine_type,
              dry_weight: vehicle.dry_weight,
              gross_weight: vehicle.gross_weight,
              hitch_weight: vehicle.hitch_weight,
              cargo_capacity: vehicle.cargo_capacity,
              fresh_water_capacity: vehicle.fresh_water_capacity,
              gray_water_capacity: vehicle.gray_water_capacity,
              black_water_capacity: vehicle.black_water_capacity,
              propane_capacity: vehicle.propane_capacity,
              home_type: vehicle.home_type,
              dwelling_type: vehicle.dwelling_type,
              foundation_type: vehicle.foundation_type,
              location_city: vehicle.location_city,
              location_state: vehicle.location_state,
              location_zip: vehicle.location_zip,
              photo_url: vehicle.photo_url,
              video_url: vehicle.video_url,
              virtual_tour_url: vehicle.virtual_tour_url,
              listing_url: vehicle.listing_url,
              images: vehicle.images,
              special_features: vehicle.special_features,
              overlay_text: vehicle.overlay_text,
              date_in_stock: vehicle.date_in_stock&.iso8601,
              date_sold: vehicle.date_sold&.iso8601
            )
          end

          json
        end
      end
    end
  end
end
