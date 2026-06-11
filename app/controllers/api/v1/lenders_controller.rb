# frozen_string_literal: true

module Api
  module V1
    # Company-scoped managed lender list. Read access mirrors who builds deals
    # (deals:create — the dropdown lives on the deal form); write access mirrors
    # how Finance settings are gated (accounting:update, which company/effective
    # admins already satisfy). company_id is NEVER permitted — it is set once via
    # @company.lenders.build and is immutable.
    class LendersController < ApplicationController
      before_action :set_company_scope
      before_action :set_lender, only: [:show, :update, :destroy]

      # GET /api/v1/lenders — active lenders for the quick-add dropdown.
      def index
        return unless authorize_action!('deals', 'create')

        lenders = @company.lenders.active.by_name
        lenders = lenders.where('name ILIKE ?', "%#{params[:search]}%") if params[:search].present?

        render json: lenders
      end

      def show
        return unless authorize_action!('deals', 'create')

        render json: @lender
      end

      # POST /api/v1/lenders — quick-add accepts just { name }; other fields optional.
      def create
        return unless authorize_action!('accounting', 'update')

        lender = @company.lenders.build(lender_params)

        if lender.save
          render json: lender, status: :created
        else
          render json: { errors: lender.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('accounting', 'update')

        if @lender.update(lender_params)
          render json: @lender
        else
          render json: { errors: @lender.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/lenders/:id — soft delete; deals retain their denormalized lender_name.
      def destroy
        return unless authorize_action!('accounting', 'update')

        @lender.soft_delete!
        render json: { message: 'Lender deleted successfully' }
      end

      private

      def set_lender
        @lender = @company.lenders.not_deleted.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def lender_params
        # company_id intentionally excluded — immutable, set via @company.lenders.build.
        params.require(:lender).permit(:name, :contact_name, :phone, :email, :website, :notes, :active)
      end
    end
  end
end
