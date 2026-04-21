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
        products = @deal.deal_products.order(created_at: :asc)
        
        render json: {
          products: products.map { |p| serialize_deal_product(p) },
          total: products.sum(:total)
        }
      end

      # GET /api/crm/deals/:deal_id/products/:id
      def show
        render json: { product: serialize_deal_product(@deal_product) }
      end

      # POST /api/crm/deals/:deal_id/products
      def create
        product = @deal.deal_products.build(deal_product_params)
        
        if product.save
          render json: { product: serialize_deal_product(product) }, status: :created
        else
          render json: { errors: product.errors.full_messages }, status: :unprocessable_entity
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

        products_data.each_with_index do |product_params, index|
          product = @deal.deal_products.build(
            transform_unified_item(product_params)
          )
          
          if product.save
            created_products << serialize_deal_product(product)
          else
            errors << { index: index, errors: product.errors.full_messages }
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
          :discount,
          :discount_type,
          :tax,
          :notes
        )
      end

      # Transform unified item structure to deal_product structure
      def transform_unified_item(item_params)
        {
          product_name: item_params[:description] || item_params[:itemName] || item_params[:product_name],
          product_sku: build_sku(item_params),
          quantity: item_params[:quantity] || 1,
          unit_price: item_params[:unitPrice] || item_params[:salePrice] || item_params[:unit_price] || 0,
          discount: item_params[:discount] || 0,
          discount_type: item_params[:discountType] || item_params[:discount_type] || 'fixed',
          tax: item_params[:taxAmount] || item_params[:tax] || 0,
          notes: build_notes(item_params)
        }
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

      def serialize_deal_product(product)
        {
          id: product.id.to_s,
          dealId: product.deal_id.to_s,
          productId: product.product_id&.to_s,
          productName: product.product_name,
          productSku: product.product_sku,
          quantity: product.quantity,
          unitPrice: product.unit_price,
          discount: product.discount,
          discountType: product.discount_type,
          tax: product.tax,
          total: product.total,
          notes: product.notes,
          createdAt: product.created_at,
          updatedAt: product.updated_at
        }
      end
    end
  end
end
