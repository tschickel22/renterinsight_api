# frozen_string_literal: true

module Api
  module V1
    class PartsController < ApplicationController
      before_action :set_company_scope
      before_action :set_part, only: [:show, :update, :destroy, :stock_by_location, :transaction_history]

      def index
        Rails.logger.info "🔧 [PartsController#index] Request from user: #{current_user&.email}, company: #{@company&.id}"
        return unless authorize_action!('inventory', 'read')
        Rails.logger.info "✅ [PartsController#index] Authorization passed"

        parts = @company.parts.where(is_deleted: [false, nil])

        # Apply filters
        parts = parts.where(category_id: params[:category_id]) if params[:category_id].present?
        parts = parts.where(active: params[:active]) if params[:active].present?
        
        # Filter parts with stock
        if params[:with_stock].present? && params[:with_stock] == 'true'
          parts = parts.joins(:stock_balances).where('stock_balances.on_hand > 0').distinct
        end
        
        if params[:search].present?
          parts = parts.where('sku ILIKE ? OR name ILIKE ?', "%#{params[:search]}%", "%#{params[:search]}%")
        end

        # RBAC + Location Filtering
        if current_user.uses_rbac?
          unless current_user.effective_admin?
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # Parts don't have location_id, but we can filter by stock_balances
              parts = parts.joins(:stock_balances)
                          .where(stock_balances: { location_id: location_ids })
                          .distinct
            else
              parts = parts.none
            end
          end
        end

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total_count = parts.count
        parts = parts.offset((page - 1) * per_page).limit(per_page)

        # Include stock levels
        parts_data = parts.includes(:category, :stock_balances).map do |part|
          part.as_json(
            only: [:id, :sku, :name, :description, :uom, :active, :default_cost, :list_price, :sale_price, :created_at, :updated_at],
            methods: [:total_on_hand, :total_available, :inventory_value],
            include: {
              category: { only: [:id, :name] }
            }
          )
        end

        render json: {
          items: parts_data,
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        return unless authorize_action!('inventory', 'read')

        render json: @part.as_json(
          methods: [:total_on_hand, :total_available, :total_reserved, :inventory_value],
          include: {
            category: { only: [:id, :name] },
            suppliers: { only: [:id, :name, :code] },
            stock_balances: {
              include: {
                location: { only: [:id, :name, :code] },
                bin: { only: [:id, :bin_code, :label] }
              }
            }
          }
        )
      end

      def create
        return unless authorize_action!('inventory', 'create')

        part = @company.parts.build(part_params.except(:supplier_ids))
        part.created_by = current_user

        if part.save
          # Handle supplier associations
          if params[:part][:supplier_ids].present?
            supplier_ids = params[:part][:supplier_ids].reject(&:blank?).map(&:to_i)
            part.supplier_ids = supplier_ids
          end
          
          render json: part, status: :created
        else
          render json: { errors: part.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('inventory', 'update')

        @part.updated_by = current_user
        
        if @part.update(part_params.except(:supplier_ids))
          # Handle supplier associations
          if params[:part][:supplier_ids].present?
            supplier_ids = params[:part][:supplier_ids].reject(&:blank?).map(&:to_i)
            @part.supplier_ids = supplier_ids
          elsif params[:part].key?(:supplier_ids)
            # If supplier_ids key exists but is empty, clear all suppliers
            @part.supplier_ids = []
          end
          
          render json: @part
        else
          # Log validation errors for debugging
          Rails.logger.error "❌ Part validation failed: #{@part.errors.full_messages.join(', ')}"
          Rails.logger.error "Part attributes: #{@part.attributes.inspect}"
          
          render json: { errors: @part.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('inventory', 'delete')

        begin
          @part.soft_delete!
          render json: { message: 'Part deleted successfully' }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end

      def stock_by_location
        return unless authorize_action!('inventory', 'read')

        stock_data = @part.stock_balances.includes(:location, :bin).map do |balance|
          {
            location_id: balance.location_id,
            location_name: balance.location.name,
            bin_id: balance.bin_id,
            bin_code: balance.bin&.bin_code,
            on_hand: balance.on_hand,
            reserved: balance.reserved,
            available: balance.available,
            last_transaction_at: balance.last_transaction_at
          }
        end

        render json: { stock: stock_data, total_on_hand: @part.total_on_hand }
      end

      def transaction_history
        return unless authorize_action!('inventory', 'read')

        transactions = @part.inventory_transactions
                           .includes(:location, :bin, :created_by)
                           .recent
                           .limit(params[:limit] || 50)

        if params[:location_id].present?
          transactions = transactions.where(location_id: params[:location_id])
        end

        render json: transactions
      end

      def stats
        Rails.logger.info "📊 [PartsController#stats] Request from user: #{current_user&.email}, company: #{@company&.id}"
        return unless authorize_action!('inventory', 'read')
        Rails.logger.info "✅ [PartsController#stats] Authorization passed"

        base_parts = @company.parts.where(is_deleted: [false, nil])

        render json: {
          total_parts: base_parts.count,
          active_parts: base_parts.where(active: true).count,
          parts_with_stock: base_parts.joins(:stock_balances).where('stock_balances.on_hand > 0').distinct.count,
          total_inventory_value: StockBalance.joins(:part)
                                            .where(parts: { company_id: @company.id })
                                            .sum('stock_balances.on_hand * COALESCE(parts.average_cost, 0)')
        }
      end

      private

      def set_part
        @part = @company.parts.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Part not found' }, status: :not_found
      end

      def part_params
        params.require(:part).permit(
          :sku, :name, :description, :category_id, :uom, :barcode,
          :manufacturer_part_no, :manufacturer_name,
          :default_cost, :list_price, :sale_price, :taxable,
          :is_serialized, :is_lot_tracked, :inventory_method,
          :weight_lbs, :length_inches, :width_inches, :height_inches,
          :active,
          supplier_ids: []
        )
        # Note: company_id NOT permitted (tenant isolation)
      end
    end
  end
end
