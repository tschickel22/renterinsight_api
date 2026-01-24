# frozen_string_literal: true

module Api
  module V1
    class StockBalancesController < ApplicationController
      before_action :set_company_scope

      def index
        return unless authorize_action!('parts', 'read')

        balances = StockBalance.joins(:part, :location)
                              .where(parts: { company_id: @company.id })
                              .where('stock_balances.on_hand > 0')

        # Filters
        balances = balances.where(part_id: params[:part_id]) if params[:part_id].present?
        balances = balances.where(location_id: params[:location_id]) if params[:location_id].present?
        balances = balances.where(bin_id: params[:bin_id]) if params[:bin_id].present?

        # Location filtering for non-admins
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          balances = location_ids.any? ? balances.where(location_id: location_ids) : balances.none
        elsif Current.location_filtered?
          balances = balances.where(location_id: Current.location_id)
        end

        # Show low stock only
        if params[:low_stock] == 'true'
          balances = balances.joins(:reorder_rules)
                           .where('stock_balances.available <= reorder_rules.reorder_point')
        end

        balances = balances.includes(:part, :location, :bin)

        render json: balances.as_json(
          include: {
            part: { only: [:id, :sku, :name] },
            location: { only: [:id, :name, :code] },
            bin: { only: [:id, :bin_code, :label] }
          }
        )
      end

      def by_part
        return unless authorize_action!('parts', 'read')

        part = @company.parts.find(params[:part_id])
        balances = part.stock_balances.where('on_hand > 0').includes(:location, :bin)

        # Location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          balances = location_ids.any? ? balances.where(location_id: location_ids) : balances.none
        elsif Current.location_filtered?
          balances = balances.where(location_id: Current.location_id)
        end

        render json: {
          part: part.as_json(only: [:id, :sku, :name]),
          balances: balances.as_json(
            include: {
              location: { only: [:id, :name, :code] },
              bin: { only: [:id, :bin_code, :label] }
            }
          ),
          total_on_hand: balances.sum(:on_hand),
          total_available: balances.sum(:available),
          total_reserved: balances.sum(:reserved)
        }
      end

      def by_location
        return unless authorize_action!('parts', 'read')

        location = @company.locations.find(params[:location_id])
        balances = StockBalance.joins(:part)
                              .where(parts: { company_id: @company.id })
                              .where(location_id: location.id)
                              .where('on_hand > 0')
                              .includes(:part, :bin)

        render json: {
          location: location.as_json(only: [:id, :name, :code]),
          balances: balances.as_json(
            include: {
              part: { only: [:id, :sku, :name] },
              bin: { only: [:id, :bin_code, :label] }
            }
          ),
          total_parts: balances.count,
          total_units: balances.sum(:on_hand)
        }
      end

      def summary
        return unless authorize_action!('parts', 'read')

        base_query = StockBalance.joins(:part).where(parts: { company_id: @company.id })

        # Location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          base_query = location_ids.any? ? base_query.where(location_id: location_ids) : base_query.none
        elsif Current.location_filtered?
          base_query = base_query.where(location_id: Current.location_id)
        end

        render json: {
          total_on_hand: base_query.sum(:on_hand),
          total_available: base_query.sum(:available),
          total_reserved: base_query.sum(:reserved),
          parts_with_stock: base_query.where('on_hand > 0').select(:part_id).distinct.count,
          locations_with_stock: base_query.where('on_hand > 0').select(:location_id).distinct.count
        }
      end

      def reserve
        return unless authorize_action!('parts', 'update')

        balance = StockBalance.joins(:part).where(parts: { company_id: @company.id }).find(params[:id])
        quantity = params[:quantity].to_f

        begin
          balance.reserve!(quantity)
          render json: balance
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end

      def release
        return unless authorize_action!('parts', 'update')

        balance = StockBalance.joins(:part).where(parts: { company_id: @company.id }).find(params[:id])
        quantity = params[:quantity].to_f

        begin
          balance.release!(quantity)
          render json: balance
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end
    end
  end
end
