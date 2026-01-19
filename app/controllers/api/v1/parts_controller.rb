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
          part_json = part.as_json(
            only: [:id, :sku, :name, :description, :uom, :active, :default_cost, :default_price, :list_price, :sale_price, :created_at, :updated_at],
            include: {
              category: { only: [:id, :name] }
            }
          )
          
          # Add location-specific stock if location is set
          if Current.location_id.present?
            part_json[:location_stock] = {
              on_hand: part.on_hand_at(Current.location_id),
              available: part.available_at(Current.location_id),
              reserved: part.reserved_at(Current.location_id)
            }
            part_json[:location_id] = Current.location_id
          end
          
          # Always include company-wide totals for reference
          part_json[:total_on_hand] = part.total_on_hand
          part_json[:total_available] = part.total_available
          part_json[:inventory_value] = part.inventory_value
          
          # Include stock at ALL locations (for transfer suggestions)
          part_json[:stock_by_location] = part.stock_balances.includes(:location).map do |balance|
            {
              location_id: balance.location_id,
              location_name: balance.location.name,
              on_hand: balance.on_hand,
              available: balance.available,
              reserved: balance.reserved
            }
          end
          
          part_json
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

      # Get part details by SKU or Barcode for auto-filling form
      def find_by_identifier
        return unless authorize_action!('inventory', 'read')

        identifier = params[:identifier]&.strip
        field = params[:field] || 'sku'  # 'sku' or 'barcode'

        if identifier.blank?
          return render json: { error: 'Identifier is required' }, status: :bad_request
        end

        part = if field == 'barcode'
          @company.parts.where(is_deleted: [false, nil]).find_by('barcode ILIKE ?', identifier)
        else
          @company.parts.where(is_deleted: [false, nil]).find_by('sku ILIKE ?', identifier)
        end

        if part
          render json: part.as_json(
            only: [:id, :sku, :name, :description, :category_id, :manufacturer_name, :barcode, :manufacturer_part_no,
                   :uom, :default_cost, :list_price, :sale_price, :taxable, :active],
            include: {
              category: { only: [:id, :name] },
              suppliers: { only: [:id, :name] }
            }
          )
        else
          render json: { error: 'Part not found' }, status: :not_found
        end
      end

      # Autocomplete suggestions from existing parts
      def autocomplete
        return unless authorize_action!('inventory', 'read')

        field = params[:field] || 'manufacturer_name'
        query = params[:query] || ''

        # Only allow specific fields
        allowed_fields = %w[manufacturer_name sku name barcode manufacturer_part_no]
        return render(json: { error: 'Invalid field' }, status: :bad_request) unless allowed_fields.include?(field)

        # Get distinct values for the field that match the query
        values = @company.parts
                        .where(is_deleted: [false, nil])
                        .where("#{field} IS NOT NULL AND #{field} != ''")
                        .where("#{field} ILIKE ?", "%#{query}%")
                        .select(field)
                        .distinct
                        .limit(20)
                        .pluck(field)
                        .compact
                        .sort

        render json: { suggestions: values }
      end

      # Get all manufacturer names with part counts for management
      def manufacturer_names
        return unless authorize_action!('inventory', 'read')

        manufacturers = @company.parts
                               .where(is_deleted: [false, nil])
                               .where("manufacturer_name IS NOT NULL AND manufacturer_name != ''")
                               .group(:manufacturer_name)
                               .count
                               .map { |name, count| { name: name, part_count: count } }
                               .sort_by { |m| m[:name].downcase }

        render json: { manufacturers: manufacturers }
      end

      # Rename a manufacturer name (updates all parts)
      def rename_manufacturer
        return unless authorize_action!('inventory', 'update')

        old_name = params[:old_name]
        new_name = params[:new_name]&.strip

        if old_name.blank? || new_name.blank?
          return render json: { error: 'Both old and new names are required' }, status: :unprocessable_entity
        end

        # Update all parts with this manufacturer name
        count = @company.parts
                       .where(is_deleted: [false, nil])
                       .where('manufacturer_name ILIKE ?', old_name)
                       .update_all(manufacturer_name: new_name, updated_at: Time.current)

        render json: { message: "Updated #{count} parts", count: count }
      end

      # Delete a manufacturer name (only if no parts use it)
      def delete_manufacturer
        return unless authorize_action!('inventory', 'update')

        name = params[:name]

        if name.blank?
          return render json: { error: 'Name is required' }, status: :unprocessable_entity
        end

        # Check if any parts use this manufacturer
        count = @company.parts.where('manufacturer_name ILIKE ?', name).where(is_deleted: [false, nil]).count

        if count > 0
          return render json: { error: "Cannot delete: #{count} parts still use this manufacturer" }, status: :unprocessable_entity
        end

        # Clear manufacturer_name from any deleted parts too
        @company.parts.where('manufacturer_name ILIKE ?', name).update_all(manufacturer_name: nil)

        render json: { message: 'Manufacturer name deleted' }
      end

      # Rename a part name (updates all parts with matching name)
      def rename_part_name
        return unless authorize_action!('inventory', 'update')

        old_name = params[:old_name]
        new_name = params[:new_name]&.strip

        if old_name.blank? || new_name.blank?
          return render json: { error: 'Both old and new names are required' }, status: :unprocessable_entity
        end

        # Update all parts with this name
        count = @company.parts
                       .where(is_deleted: [false, nil])
                       .where('name ILIKE ?', old_name)
                       .update_all(name: new_name, updated_at: Time.current)

        render json: { message: "Updated #{count} parts", count: count }
      end

      # Delete a part name (only if no parts use it)
      def delete_part_name
        return unless authorize_action!('inventory', 'update')

        name = params[:name]

        if name.blank?
          return render json: { error: 'Name is required' }, status: :unprocessable_entity
        end

        # Check if any parts use this name
        count = @company.parts.where('name ILIKE ?', name).where(is_deleted: [false, nil]).count

        if count > 0
          return render json: { error: "Cannot delete: #{count} parts still use this name" }, status: :unprocessable_entity
        end

        # This shouldn't happen (parts require names), but just in case
        render json: { message: 'Part name deleted' }
      end

      private

      def set_part
        @part = @company.parts.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Part not found' }, status: :not_found
      end

      def part_params
        params.require(:part).permit(
          :sku, :name, :description, :category_id, :manufacturer_name, :uom, :barcode,
          :manufacturer_part_no,
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
