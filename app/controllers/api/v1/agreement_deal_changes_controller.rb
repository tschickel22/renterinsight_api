# frozen_string_literal: true

module Api
  module V1
    # Lines added or changed on an agreement's rows, offered back to its deal.
    # See Agreements::DealChanges.
    class AgreementDealChangesController < ApplicationController
      before_action :set_company_scope
      before_action :set_agreement

      # GET /api/v1/agreements/:id/deal_changes
      def show
        return unless authorize_action!('agreements', 'read')

        result = ::Agreements::DealChanges.new(@agreement).list
        render json: { changes: result.changes, blocked_reason: result.blocked_reason, warning: result.warning }
      end

      # POST /api/v1/agreements/:id/deal_changes  { change_ids: [...] }
      def create
        return unless authorize_action!('agreements', 'update')
        return unless authorize_action!('deals', 'update')

        ids = Array(params[:change_ids]).map(&:to_s)
        result = ::Agreements::DealChanges.new(@agreement).apply(ids)
        render json: result
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      private

      def set_agreement
        @agreement = @company.agreements.active.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Agreement not found' }, status: :not_found
      end
    end
  end
end
