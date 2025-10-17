# frozen_string_literal: true

module Api
  module V1
    class VehiclesController < ApplicationController
      before_action :set_vehicle, only: [:show, :update, :destroy]

      def index
        vehicles = Vehicle.active
        
        # Filters
        vehicles = vehicles.where(status: params[:status]) if params[:status].present?
        vehicles = vehicles.where(condition: params[:condition]) if params[:condition].present?
        vehicles = vehicles.by_year(params[:year]) if params[:year].present?
        vehicles = vehicles.by_make(params[:make]) if params[:make].present?
        
        # Search
        if params[:search].present?
          search = "%#{params[:search]}%"
          vehicles = vehicles.where(
            "stock_number LIKE ? OR vin LIKE ? OR make LIKE ? OR model LIKE ?",
            search, search, search, search
          )
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        vehicles = vehicles.order("#{sort_by} #{sort_order}")

        # Pagination
        page = params[:page]&.to_i || 1
        per_page = params[:per_page]&.to_i || 25
        total_count = vehicles.count
        vehicles = vehicles.offset((page - 1) * per_page).limit(per_page)

        render json: {
          vehicles: vehicles.map { |v| vehicle_json(v) },
          meta: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        render json: { vehicle: vehicle_json(@vehicle) }
      end

      def create
        vehicle = Vehicle.new(vehicle_params)

        if vehicle.save
          render json: { vehicle: vehicle_json(vehicle) }, status: :created
        else
          render json: { errors: vehicle.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @vehicle.update(vehicle_params)
          render json: { vehicle: vehicle_json(@vehicle) }
        else
          render json: { errors: @vehicle.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @vehicle.soft_delete
        head :no_content
      end

      def stats
        render json: {
          total: Vehicle.active.count,
          available: Vehicle.available.count,
          by_status: Vehicle.active.group(:status).count,
          by_condition: Vehicle.active.group(:condition).count,
          total_value: Vehicle.active.sum(:price).to_f
        }
      end

      private

      def set_vehicle
        @vehicle = Vehicle.active.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Vehicle not found' }, status: :not_found
      end

      def vehicle_params
        params.require(:vehicle).permit(
          :stock_number, :vin, :year, :make, :model, :trim, :color,
          :condition, :status, :price, :cost, :mileage, :description,
          :notes, :location, :date_in_stock, :date_sold, features: []
        )
      end

      def vehicle_json(vehicle)
        {
          id: vehicle.id.to_s,
          stock_number: vehicle.stock_number,
          vin: vehicle.vin,
          year: vehicle.year,
          make: vehicle.make,
          model: vehicle.model,
          trim: vehicle.trim,
          color: vehicle.color,
          condition: vehicle.condition,
          status: vehicle.status,
          price: vehicle.price.to_f,
          cost: vehicle.cost&.to_f,
          mileage: vehicle.mileage,
          description: vehicle.description,
          notes: vehicle.notes,
          features: vehicle.features,
          location: vehicle.location,
          display_name: vehicle.display_name,
          date_in_stock: vehicle.date_in_stock,
          date_sold: vehicle.date_sold,
          created_at: vehicle.created_at,
          updated_at: vehicle.updated_at
        }
      end
    end
  end
end
