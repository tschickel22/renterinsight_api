# frozen_string_literal: true

module Api
  module Crm
    class DealProductsController < ApplicationController
      include RbacAuthorization
      rbac_resource :deals,
        read_actions: [:index, :show],
        create_actions: [:create, :bulk_create],
        update_actions: [:update, :destroy]

      before_action :set_company_scope
      before_action :set_deal
      before_action :set_deal_product, only: [:show, :update, :destroy]

      # GET /api/crm/deals/:deal_id/products
      def index
        products = @deal.deal_products.order(created_at: :asc).to_a

        render json: {
          products: products.map { |p| serialize_deal_product(p) },
          total: products.sum { |p| p.total.to_f }.round(2),
          total_cost: products.sum { |p| p.line_cost_total }.round(2),
          total_profit: products.sum { |p| p.line_profit }.round(2)
        }
      end

      # GET /api/crm/deals/:deal_id/products/:id
      def show
        render json: { product: serialize_deal_product(@deal_product) }
      end

      # POST /api/crm/deals/:deal_id/products
      def create
        attrs = deal_product_params
        vehicle_id = extract_vehicle_id_from_attrs(attrs)

        ActiveRecord::Base.transaction do
          product = @deal.deal_products.build(attrs)
          apply_vehicle_cost_default!(product, vehicle_id) unless attrs.key?(:cost)

          if product.save
            link_vehicle_to_deal(vehicle_id) if vehicle_id
            render json: { product: serialize_deal_product(product) }, status: :created
          else
            render json: { errors: product.errors.full_messages }, status: :unprocessable_entity
            raise ActiveRecord::Rollback
          end
        end
      end

      # PATCH/PUT /api/crm/deals/:deal_id/products/:id
      def update
        if @deal_product.update(deal_product_params)
          render json: { product: serialize_deal_product(@deal_product) }
        else
          render json: { errors: @deal_product.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/deals/:deal_id/products/:id
      def destroy
        @deal_product.destroy
        head :no_content
      end

      # POST /api/crm/deals/:deal_id/products/bulk_create
      def bulk_create
        products_data = params.require(:products)
        created_products = []
        errors = []
        vehicle_ids_in_batch = []

        ActiveRecord::Base.transaction do
          products_data.each_with_index do |product_params, index|
            transformed = transform_unified_item(product_params)
            vehicle_id = extract_vehicle_id_from_item(product_params, transformed)
            product = @deal.deal_products.build(transformed)
            apply_vehicle_cost_default!(product, vehicle_id) unless transformed.key?(:cost)

            if product.save
              created_products << serialize_deal_product(product)
              vehicle_ids_in_batch << vehicle_id if vehicle_id
            else
              errors << { index: index, errors: product.errors.full_messages }
            end
          end

          if errors.any?
            raise ActiveRecord::Rollback
          end

          # If the batch identified vehicle line items, link the (single) vehicle to the deal.
          # Ambiguity guard: if the batch references multiple distinct vehicles we leave the
          # deal alone and log — the writer can't pick a "primary" without more signal.
          distinct = vehicle_ids_in_batch.uniq
          if distinct.size == 1
            link_vehicle_to_deal(distinct.first)
          elsif distinct.size > 1
            Rails.logger.warn(
              "[DealProducts] Deal #{@deal.id} bulk_create added #{distinct.size} distinct vehicle " \
              "line items (#{distinct.join(', ')}); not auto-linking deal.vehicle_id."
            )
          end
        end

        if errors.empty?
          render json: {
            products: created_products,
            total: @deal.deal_products.sum(:total)
          }, status: :created
        else
          render json: {
            products: created_products,
            errors: errors
          }, status: :unprocessable_entity
        end
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [DealProductsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [DealProductsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [DealProductsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [DealProductsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_deal
        @deal = @company.deals.find_by(id: params[:deal_id])
        unless @deal
          render json: { error: 'Deal not found or access denied' }, status: :not_found
          return
        end
      end

      def set_deal_product
        @deal_product = @deal.deal_products.find_by(id: params[:id])
        unless @deal_product
          render json: { error: 'Product not found' }, status: :not_found
          return
        end
      end

      def deal_product_params
        params.require(:product).permit(
          :product_id,
          :product_name,
          :product_sku,
          :quantity,
          :unit_price,
          :cost,
          :discount,
          :discount_type,
          :tax,
          :notes
        )
      end

      # Transform unified item structure to deal_product structure
      def transform_unified_item(item_params)
        attrs = {
          product_name: item_params[:description] || item_params[:itemName] || item_params[:product_name],
          product_sku: build_sku(item_params),
          quantity: item_params[:quantity] || 1,
          unit_price: item_params[:unitPrice] || item_params[:salePrice] || item_params[:unit_price] || 0,
          discount: item_params[:discount] || 0,
          discount_type: item_params[:discountType] || item_params[:discount_type] || 'fixed',
          tax: item_params[:taxAmount] || item_params[:tax] || 0,
          notes: build_notes(item_params)
        }

        # Only set :cost when the caller explicitly provides one. Leaving the key absent
        # lets the column default (0) stand, and lets vehicle line items auto-fill from the
        # vehicle's structured_cost downstream.
        explicit_cost = extract_explicit_cost(item_params)
        attrs[:cost] = explicit_cost unless explicit_cost.nil?

        attrs
      end

      # Pull an explicitly-provided per-unit cost from a unified item payload, tolerating
      # the various field names the frontend may send. Returns nil when none is present.
      def extract_explicit_cost(item_params)
        raw = item_params[:cost] || item_params[:unitCost] || item_params[:unit_cost] ||
              item_params[:itemCost] || item_params[:item_cost]
        raw.nil? || raw.to_s.strip.empty? ? nil : raw
      end

      # For vehicle line items added from inventory, fill the per-unit cost from the vehicle's
      # structured_cost when the caller did not supply one. structured_cost returns nil when no
      # cost has been entered (0 == missing), in which case we leave the column default (0).
      def apply_vehicle_cost_default!(product, vehicle_id)
        return unless vehicle_id.present?

        vehicle = @company.vehicles.find_by(id: vehicle_id)
        return unless vehicle

        structured = vehicle.structured_cost
        product.cost = structured unless structured.nil?
      end

      def build_sku(item_params)
        item_type = item_params[:itemType] || item_params[:item_type]
        itemable_id = item_params[:itemableId] || item_params[:itemable_id]
        
        if item_type && itemable_id
          "#{item_type.upcase}-#{itemable_id}"
        else
          item_params[:product_sku] || "CUSTOM-#{SecureRandom.hex(4)}"
        end
      end

      def calculate_discount_amount(item_params)
        discount = item_params[:discount] || 0
        discount_type = item_params[:discountType] || item_params[:discount_type] || 'fixed'
        unit_price = item_params[:unitPrice] || item_params[:unit_price] || 0
        quantity = item_params[:quantity] || 1

        if discount_type == 'percentage'
          (unit_price * quantity * discount / 100.0)
        else
          discount.to_f
        end
      end

      def build_notes(item_params)
        notes_parts = []
        
        # Add item type and ID if present
        if item_params[:itemType] && item_params[:itemableId]
          notes_parts << "Type: #{item_params[:itemType]}, ID: #{item_params[:itemableId]}"
        end
        
        # Add user notes if present
        if item_params[:notes].present?
          notes_parts << item_params[:notes]
        end
        
        notes_parts.join(" | ")
      end

      # Recognize a vehicle line item from the single-create payload. Signal is the SKU
      # the bulk path bakes in (`VEHICLE-<id>`). Name alone ("Primary Vehicle") doesn't
      # identify *which* vehicle, so we don't infer from name here.
      def extract_vehicle_id_from_attrs(attrs)
        sku = attrs[:product_sku] || attrs['product_sku']
        return nil if sku.blank?
        match = sku.to_s.match(/\AVEHICLE-(\d+)\z/i)
        match && match[1].to_i
      end

      # Same idea for the bulk path: prefer the explicit itemType/itemableId pair the
      # frontend sends; fall back to the SKU written by transform_unified_item.
      def extract_vehicle_id_from_item(raw_params, transformed)
        item_type = raw_params[:itemType] || raw_params[:item_type]
        itemable_id = raw_params[:itemableId] || raw_params[:itemable_id]
        if item_type.to_s.downcase == 'vehicle' && itemable_id.present?
          return itemable_id.to_i
        end
        extract_vehicle_id_from_attrs(transformed)
      end

      # Set deal.vehicle_id from a freshly-added vehicle line item. Conservative:
      #  - verify the vehicle exists in this company (cross-company guard)
      #  - never overwrite a non-nil vehicle_id that points to a different vehicle
      def link_vehicle_to_deal(vehicle_id)
        return unless vehicle_id.present?

        unless @company.vehicles.where(id: vehicle_id).exists?
          Rails.logger.warn(
            "[DealProducts] Deal #{@deal.id}: line item references vehicle #{vehicle_id} " \
            "not found in company #{@company.id}; not linking."
          )
          return
        end

        if @deal.vehicle_id.present? && @deal.vehicle_id != vehicle_id.to_i
          Rails.logger.warn(
            "[DealProducts] Deal #{@deal.id} already linked to vehicle #{@deal.vehicle_id}; " \
            "refusing to overwrite with #{vehicle_id} from new line item."
          )
          return
        end

        return if @deal.vehicle_id == vehicle_id.to_i

        @deal.update(vehicle_id: vehicle_id)
      end

      def serialize_deal_product(product)
        {
          id: product.id.to_s,
          dealId: product.deal_id.to_s,
          productId: product.product_id&.to_s,
          productName: product.product_name,
          productSku: product.product_sku,
          quantity: product.quantity,
          unitPrice: product.unit_price,
          cost: product.cost,
          lineCostTotal: product.line_cost_total,
          discount: product.discount,
          discountType: product.discount_type,
          tax: product.tax,
          total: product.total,
          lineProfit: product.line_profit,
          notes: product.notes,
          createdAt: product.created_at,
          updatedAt: product.updated_at
        }
      end
    end
  end
end
