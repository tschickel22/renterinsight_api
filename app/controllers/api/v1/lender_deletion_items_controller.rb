# frozen_string_literal: true

module Api
  module V1
    # Finance-settings CRUD for a lender's deletion schedule (Max Advance Phase 2),
    # nested under /api/v1/lenders/:lender_id/deletion_items.
    #
    # Reads available to deal-creators (deals:create); writes admin/finance-gated
    # (accounting:update). company_id/lender_id never permitted (scope/route derived).
    class LenderDeletionItemsController < ApplicationController
      before_action :set_company_scope
      before_action :set_lender
      before_action :set_item, only: [:show, :update, :destroy]

      def index
        return unless authorize_action!('deals', 'create')
        render json: @lender.deletion_items.order(:name).map { |i| item_json(i) }
      end

      def show
        return unless authorize_action!('deals', 'create')
        render json: item_json(@item)
      end

      def create
        return unless authorize_action!('accounting', 'update')
        item = @lender.deletion_items.build(item_params)
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
        @item = @lender.deletion_items.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def item_params
        params.require(:deletion_item).permit(
          :name, :amount, :invoice_reference, :single_amount, :multi_amount, :active
        )
      end

      def item_json(i)
        {
          id: i.id,
          lenderId: i.lender_id,
          name: i.name,
          amount: i.amount,
          invoiceReference: i.invoice_reference,
          singleAmount: i.single_amount,
          multiAmount: i.multi_amount,
          active: i.active,
          createdAt: i.created_at,
          updatedAt: i.updated_at
        }
      end
    end
  end
end
