# frozen_string_literal: true

module Api
  module Partner
    module V1
      class LocationsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :location

        before_action :authorize_locations
        before_action :set_location, only: [:show, :update, :destroy]

        # GET /api/partner/v1/locations
        def index
          locations = company_scope(Location).where(is_deleted: false)

          # Filters
          locations = locations.where(active: params[:active] == "true") if params[:active].present?
          locations = locations.where(city: params[:city]) if params[:city].present?
          locations = locations.where(state: params[:state]) if params[:state].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            locations = locations.where("name ILIKE :q OR code ILIKE :q OR city ILIKE :q", q: q)
          end

          # Cursor-based pagination
          locations = locations.order(:id)
          locations = locations.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          locations = locations.limit(limit + 1)

          records = locations.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |l| location_json(l) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/locations/:id
        def show
          render json: { data: location_json(@location, detailed: true) }
        end

        # POST /api/partner/v1/locations
        def create
          location = company_scope(Location).new(location_params)

          if location.save
            render json: { data: location_json(location, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: location.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/locations/:id
        def update
          if @location.update(location_params)
            render json: { data: location_json(@location, detailed: true) }
          else
            render json: { error: "Validation failed", details: @location.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/locations/:id
        def destroy
          @location.update!(is_deleted: true, deleted_at: Time.current, active: false)
          render json: { data: { id: @location.id, deleted: true } }
        end

        private

        def authorize_locations
          case action_name
          when "index", "show"
            authorize_permission!(:locations, :read)
          when "create"
            authorize_permission!(:locations, :create)
          when "update"
            authorize_permission!(:locations, :update)
          when "destroy"
            authorize_permission!(:locations, :delete)
          end
        end

        def set_location
          @location = company_scope(Location).where(is_deleted: false).find(params[:id])
        end

        def location_params
          params.permit(
            :name, :code, :description, :phone, :email,
            :address_line1, :address_line2, :city, :state, :zip_code, :country,
            :timezone, :delivery_radius_miles, :active,
            :fiscal_year_start_month, :external_payments_property_id,
            business_hours: {}
          )
        end

        def location_json(location, detailed: false)
          json = {
            id: location.id,
            name: location.name,
            code: location.code,
            active: location.active,
            phone: location.phone,
            email: location.email,
            city: location.city,
            state: location.state,
            zip_code: location.zip_code,
            country: location.country,
            timezone: location.timezone,
            created_at: location.created_at&.iso8601,
            updated_at: location.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              description: location.description,
              address_line1: location.address_line1,
              address_line2: location.address_line2,
              delivery_radius_miles: location.delivery_radius_miles,
              business_hours: location.business_hours,
              fiscal_year_start_month: location.fiscal_year_start_month,
              external_payments_property_id: location.external_payments_property_id,
              is_default: location.is_default
            )
          end

          json
        end
      end
    end
  end
end
