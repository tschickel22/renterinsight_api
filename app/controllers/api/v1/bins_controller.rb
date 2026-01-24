# frozen_string_literal: true

module Api
  module V1
    class BinsController < ApplicationController
      before_action :set_company_scope
      before_action :set_bin, only: [:show, :update, :destroy]

      def index
        return unless authorize_action!('bins', 'read')

        bins = Bin.joins(:location)
                  .where(locations: { company_id: @company.id })
                  .where(is_deleted: [false, nil])

        # Filter by location
        if params[:location_id].present?
          bins = bins.where(location_id: params[:location_id])
        elsif Current.location_filtered?
          bins = bins.where(location_id: Current.location_id)
        end

        bins = bins.where(active: params[:active]) if params[:active].present?
        bins = bins.where(bin_type: params[:bin_type]) if params[:bin_type].present?
        
        if params[:search].present?
          bins = bins.where('bin_code ILIKE ? OR label ILIKE ?', "%#{params[:search]}%", "%#{params[:search]}%")
        end

        bins = bins.order(:bin_code)

        render json: bins.as_json(
          include: {
            location: { only: [:id, :name, :code] }
          }
        )
      end

      def show
        return unless authorize_action!('bins', 'read')

        render json: @bin.as_json(
          include: {
            location: { only: [:id, :name, :code] },
            stock_balances: {
              where: { on_hand: (0.1..Float::INFINITY) },
              include: {
                part: { only: [:id, :sku, :name] }
              }
            }
          }
        )
      end

      def create
        return unless authorize_action!('bins', 'create')

        location = @company.locations.find(params[:bin][:location_id])
        bin = location.bins.build(bin_params)

        if bin.save
          render json: bin, status: :created
        else
          render json: { errors: bin.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('bins', 'update')

        if @bin.update(bin_params)
          render json: @bin
        else
          render json: { errors: @bin.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('bins', 'delete')

        begin
          @bin.soft_delete!
          render json: { message: 'Bin deleted successfully' }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end

      private

      def set_bin
        @bin = Bin.joins(:location)
                  .where(locations: { company_id: @company.id })
                  .find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Bin not found' }, status: :not_found
      end

      def bin_params
        params.require(:bin).permit(
          :location_id, :bin_code, :label, :bin_type,
          :capacity_cubic_feet, :notes, :is_default, :active
        )
      end
    end
  end
end
