# frozen_string_literal: true

require 'csv'

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

        # Apply non-search filters (category, active status)
        parts = parts.where(category_id: params[:category_id]) if params[:category_id].present?
        parts = parts.where(active: params[:active]) if params[:active].present?
        
        # Filter parts with stock
        if params[:with_stock].present? && params[:with_stock] == 'true'
          parts = parts.joins(:stock_balances).where('stock_balances.on_hand > 0').distinct
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

        # Count stats BEFORE search filter (stats tiles show ALL parts)
        all_parts_count = parts.count
        status_counts = {
          active: parts.where(active: true).count,
          inactive: parts.where(active: false).count,
          with_stock: parts.joins(:stock_balances).where('stock_balances.on_hand > 0').distinct.count,
          low_stock: parts.joins(:stock_balances)
                         .where('stock_balances.on_hand > 0 AND stock_balances.on_hand < 10')
                         .distinct.count
        }

        # Apply search filter (searches sku, name, description, manufacturer, barcode, part number)
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          parts = parts.where(
            "parts.sku ILIKE ? OR parts.name ILIKE ? OR parts.description ILIKE ? OR parts.manufacturer_name ILIKE ? OR parts.barcode ILIKE ? OR parts.manufacturer_part_no ILIKE ?",
            search_term, search_term, search_term, search_term, search_term, search_term
          )
        end

        # Apply sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        
        # Handle sorting by category (joined table)
        if sort_by == 'category'
          parts = parts.left_joins(:category).order("part_categories.name #{sort_order}")
        else
          parts = parts.order(sort_by => sort_order)
        end

        # Count AFTER search filter (for pagination)
        filtered_count = parts.count

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
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
            total: filtered_count,  # For pagination (filtered results)
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: status_counts.merge(total: all_parts_count)  # For tiles (unfiltered totals)
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
          # Return clean validation messages (without "Validation failed:" prefix)
          error_messages = e.record&.errors&.full_messages || [e.message]
          render json: { errors: error_messages }, status: :unprocessable_entity
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
                                            .where(parts: { company_id: @company.id, is_deleted: [false, nil] })
                                            .sum('stock_balances.on_hand * COALESCE(parts.average_cost, parts.default_cost, 0)')
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

      # Upload image to part
      def upload_image
        return unless authorize_action!('inventory', 'update')

        @part = @company.parts.find(params[:id])
        
        if params[:image].present?
          # Read the uploaded file
          uploaded_file = params[:image]
          
          # Generate unique filename
          file_extension = File.extname(uploaded_file.original_filename)
          unique_filename = "parts/#{@part.id}/#{SecureRandom.uuid}#{file_extension}"
          
          # For now, store as Base64 in JSONB (Phase 1 - simple implementation)
          # In Phase 2, we can move to S3/Cloudinary
          image_data = {
            url: "data:#{uploaded_file.content_type};base64,#{Base64.strict_encode64(uploaded_file.read)}",
            filename: uploaded_file.original_filename,
            content_type: uploaded_file.content_type,
            size: uploaded_file.size,
            uploaded_at: Time.current.iso8601
          }
          
          # Initialize images array if nil
          @part.images ||= []
          @part.images << image_data
          @part.save!
          
          render json: { part: @part.as_json, message: 'Image uploaded successfully' }
        else
          render json: { error: 'No image provided' }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Image upload failed: #{e.message}"
        render json: { error: 'Image upload failed' }, status: :internal_server_error
      end

      # Delete image from part
      def delete_image
        return unless authorize_action!('inventory', 'update')

        @part = @company.parts.find(params[:id])
        image_index = params[:image_index].to_i
        
        if @part.images && @part.images[image_index]
          @part.images.delete_at(image_index)
          @part.save!
          
          render json: { part: @part.as_json, message: 'Image deleted successfully' }
        else
          render json: { error: 'Image not found' }, status: :not_found
        end
      rescue => e
        Rails.logger.error "Image deletion failed: #{e.message}"
        render json: { error: 'Image deletion failed' }, status: :internal_server_error
      end

      # Export parts to CSV
      def export
        return unless authorize_action!('inventory', 'read')

        parts = @company.parts.where(is_deleted: [false, nil])

        # Apply same filters as index
        parts = parts.where(category_id: params[:category_id]) if params[:category_id].present?
        parts = parts.where(active: params[:active]) if params[:active].present?
        
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
              parts = parts.joins(:stock_balances)
                          .where(stock_balances: { location_id: location_ids })
                          .distinct
            else
              parts = parts.none
            end
          end
        end

        # Include necessary associations
        parts = parts.includes(:category, stock_balances: :location)

        export_type = params[:export_type] || 'all_locations'

        # Generate CSV based on export type
        csv_data = if export_type == 'current_location'
          generate_current_location_csv(parts)
        else
          generate_all_locations_csv(parts)
        end

        filename = export_type == 'current_location' ? 
          "parts-export-current-location-#{Date.today}.csv" : 
          "parts-export-all-locations-#{Date.today}.csv"

        send_data csv_data, 
                  filename: filename,
                  type: 'text/csv',
                  disposition: 'attachment'
      end

      private

      def set_part
        @part = @company.parts.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Part not found' }, status: :not_found
      end

      def generate_current_location_csv(parts)
        current_location = Current.location_id ? Location.find_by(id: Current.location_id) : nil
        
        CSV.generate(headers: true) do |csv|
          # Add location header info if location is selected
          if current_location
            csv << ['Location:', current_location.name]
            csv << ['Code:', current_location.code] if current_location.code.present?
            
            # Build address line
            address_parts = []
            address_parts << current_location.address if current_location.respond_to?(:address) && current_location.address.present?
            address_parts << current_location.street if current_location.respond_to?(:street) && current_location.street.present?
            csv << ['Address:', address_parts.join(', ')] if address_parts.any?
            
            # Build city/state/zip line
            location_parts = []
            location_parts << current_location.city if current_location.respond_to?(:city) && current_location.city.present?
            location_parts << current_location.state if current_location.respond_to?(:state) && current_location.state.present?
            location_parts << current_location.zip_code if current_location.respond_to?(:zip_code) && current_location.zip_code.present?
            csv << ['City/State/Zip:', location_parts.join(', ')] if location_parts.any?
            
            csv << ['Phone:', current_location.phone] if current_location.phone.present?
            csv << [] # Blank row separator
          end
          
          # Column headers
          csv << [
            'SKU',
            'Name',
            'Description',
            'Category',
            'Manufacturer',
            'Manufacturer Part #',
            'Barcode',
            'UOM',
            'Default Cost',
            'List Price',
            'Sale Price',
            'On Hand',
            'Available',
            'Reserved',
            'Inventory Value',
            'Active',
            'Created At'
          ]

          parts.each do |part|
            if current_location
              on_hand = part.on_hand_at(current_location.id)
              available = part.available_at(current_location.id)
              reserved = part.reserved_at(current_location.id)
              cost = part.average_cost || part.default_cost || 0
              value = on_hand * cost
            else
              on_hand = part.total_on_hand
              available = part.total_available
              reserved = part.total_reserved
              value = part.inventory_value
            end

            csv << [
              part.sku,
              part.name,
              part.description,
              part.category&.name,
              part.manufacturer_name,
              part.manufacturer_part_no,
              part.barcode,
              part.uom,
              part.default_cost,
              part.list_price,
              part.sale_price,
              on_hand,
              available,
              reserved,
              value,
              part.active ? 'Yes' : 'No',
              part.created_at.strftime('%Y-%m-%d %H:%M:%S')
            ]
          end
        end
      end

      def generate_all_locations_csv(parts)
        CSV.generate(headers: true) do |csv|
          csv << [
            'SKU',
            'Name',
            'Description',
            'Category',
            'Manufacturer',
            'Manufacturer Part #',
            'Barcode',
            'UOM',
            'Default Cost',
            'List Price',
            'Sale Price',
            'Location',
            'Location Code',
            'On Hand',
            'Available',
            'Reserved',
            'Location Value',
            'Total On Hand (All Locations)',
            'Total Available (All Locations)',
            'Total Value (All Locations)',
            'Active',
            'Created At'
          ]

          parts.each do |part|
            # If part has stock balances, create a row for each location
            if part.stock_balances.any?
              part.stock_balances.each do |balance|
                cost = part.average_cost || part.default_cost || 0
                location_value = balance.on_hand * cost

                csv << [
                  part.sku,
                  part.name,
                  part.description,
                  part.category&.name,
                  part.manufacturer_name,
                  part.manufacturer_part_no,
                  part.barcode,
                  part.uom,
                  part.default_cost,
                  part.list_price,
                  part.sale_price,
                  balance.location.name,
                  balance.location.code,
                  balance.on_hand,
                  balance.available,
                  balance.reserved,
                  location_value,
                  part.total_on_hand,
                  part.total_available,
                  part.inventory_value,
                  part.active ? 'Yes' : 'No',
                  part.created_at.strftime('%Y-%m-%d %H:%M:%S')
                ]
              end
            else
              # Part has no stock anywhere - single row with zeros
              csv << [
                part.sku,
                part.name,
                part.description,
                part.category&.name,
                part.manufacturer_name,
                part.manufacturer_part_no,
                part.barcode,
                part.uom,
                part.default_cost,
                part.list_price,
                part.sale_price,
                'No Stock',
                '',
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                part.active ? 'Yes' : 'No',
                part.created_at.strftime('%Y-%m-%d %H:%M:%S')
              ]
            end
          end
        end
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
        # Note: images are uploaded via upload_image endpoint, not in params
      end
    end
  end
end
