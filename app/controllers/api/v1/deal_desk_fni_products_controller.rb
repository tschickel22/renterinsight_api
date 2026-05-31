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

      private

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
