# frozen_string_literal: true

module Api
  module V1
    # Read-only list of F&I products to populate the Deal Desk F&I menu dropdown.
    # @company-scoped, gated by deal_desk:read. default_cost is INTERNAL (feeds back-end
    # gross) — exposed only to users with the deals view_cost_details permission, matching
    # the scenario gross membrane.
    class DealDeskFniProductsController < ApplicationController
      include ModuleAccessRequired

      before_action :set_company_scope
      require_module! 'sales.deal_desk'

      # GET /api/v1/deal_desk/fni_products
      def index
        return unless authorize_action!('deal_desk', 'read')

        products = @company.fni_products.active.ordered
        render json: { fni_products: products.map { |p| product_json(p) } }
      end

      # POST /api/v1/deal_desk/fni_products
      def create
        return unless authorize_action!('deal_desk', 'update')

        product = @company.fni_products.new(fni_product_params)
        product.active = true if product.active.nil?
        # is_seeded is system-managed — user-created products are never "seeded".
        product.is_seeded = false

        if product.save
          render json: { fni_product: product_json(product) }, status: :created
        else
          render json: { errors: product.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/deal_desk/fni_products/:id
      def update
        return unless authorize_action!('deal_desk', 'update')

        product = @company.fni_products.find(params[:id])
        if product.update(fni_product_params)
          render json: { fni_product: product_json(product) }
        else
          render json: { errors: product.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'F&I product not found' }, status: :not_found
      end

      # DELETE /api/v1/deal_desk/fni_products/:id
      # Soft-deactivate rather than destroy: F&I products may be referenced by historical
      # scenarios/deals, so we never orphan those references — we just remove the product
      # from the active menu. (The index only returns active products.)
      def destroy
        return unless authorize_action!('deal_desk', 'update')

        product = @company.fni_products.find(params[:id])
        product.update!(active: false)
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'F&I product not found' }, status: :not_found
      end

      private

      # default_cost is INTERNAL — only writable by users who can see costs (same membrane
      # as the read serializer). Strip it from params otherwise so a non-cost user can't
      # set/overwrite it. company_id and is_seeded are never client-settable.
      def fni_product_params
        permitted = params.require(:fni_product).permit(
          :name, :product_type, :default_price, :default_cost, :active, :position
        )
        permitted.delete(:default_cost) unless can_view_costs?
        permitted
      end

      def product_json(product)
        base = {
          id: product.id, name: product.name, product_type: product.product_type,
          default_price: product.default_price, is_seeded: product.is_seeded
        }
        base[:default_cost] = product.default_cost if can_view_costs?
        base
      end

      def can_view_costs?
        return @can_view_costs if defined?(@can_view_costs)

        @can_view_costs = current_user&.has_permission?('deals', 'read', scope: 'view_cost_details') || false
      end
    end
  end
end
