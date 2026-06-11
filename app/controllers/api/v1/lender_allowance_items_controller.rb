# frozen_string_literal: true

module Api
  module V1
    # Finance-settings CRUD for a lender's allowance schedule (Max Advance Phase 2),
    # nested under /api/v1/lenders/:lender_id/allowance_items.
    #
    # Reads (index/show) are available to deal-creators (deals:create) so the future
    # calculator can run; writes are admin/finance-gated (accounting:update). company_id
    # and lender_id are NEVER permitted — derived from scope and route.
    class LenderAllowanceItemsController < ApplicationController
      before_action :set_company_scope
      before_action :set_lender
      before_action :set_item, only: [:show, :update, :destroy]

      def index
        return unless authorize_action!('deals', 'create')
        render json: @lender.allowance_items.order(:category, :name).map { |i| item_json(i) }
      end

      def show
        return unless authorize_action!('deals', 'create')
        render json: item_json(@item)
      end

      def create
        return unless authorize_action!('accounting', 'update')
        item = @lender.allowance_items.build(item_params)
        item.company = @company
        if item.save
          render json: item_json(item), status: :created
        else
          render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('accounting', 'update')
        if @item.update(item_params)
          render json: item_json(@item)
        else
          render json: { errors: @item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('accounting', 'update')
        @item.destroy
        head :no_content
      end

      private

      def set_lender
        @lender = @company.lenders.not_deleted.find(params[:lender_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Lender not found' }, status: :not_found
      end

      def set_item
        @item = @lender.allowance_items.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def item_params
        params.require(:allowance_item).permit(
          :category, :name, :standard_allowance, :maximum_allowance, :pricing_basis,
          :material, :wind_zone2_adder_per_side, :wind_zone3_adder_per_side, :active
        )
      end

      def item_json(i)
        {
          id: i.id,
          lenderId: i.lender_id,
          category: i.category,
          name: i.name,
          standardAllowance: i.standard_allowance,
          maximumAllowance: i.maximum_allowance,
          dealerCost: i.dealer_cost,
          dealerPrice: i.dealer_price,
          companyAllowanceDefaultId: i.company_allowance_default_id,
          pricingBasis: i.pricing_basis,
          material: i.material,
          windZone2AdderPerSide: i.wind_zone2_adder_per_side,
          windZone3AdderPerSide: i.wind_zone3_adder_per_side,
          active: i.active,
          createdAt: i.created_at,
          updatedAt: i.updated_at
        }
      end
    end
  end
end
