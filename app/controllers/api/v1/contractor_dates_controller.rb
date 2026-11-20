# frozen_string_literal: true

# E107: the dealer confirms a contractor's proposed dates, or keeps their own.
module Api
  module V1
    class ContractorDatesController < ApplicationController
      before_action :set_company_scope
      before_action :set_assignment

      # POST /api/v1/contractor_assignments/:id/confirm_dates
      def confirm
        return unless authorize_action!('projects', 'update')

        ContractorDates.new(@assignment).confirm!(current_user)
        render json: dates_json
      rescue ContractorDates::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/contractor_assignments/:id/decline_dates
      def decline
        return unless authorize_action!('projects', 'update')

        ContractorDates.new(@assignment).decline!(current_user)
        render json: dates_json
      rescue ContractorDates::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_assignment
        @assignment = @company.contractor_assignments.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def dates_json
        @assignment.reload
        target = ContractorDates.new(@assignment).proposed_target
        {
          id: @assignment.id, dates_status: @assignment.dates_status,
          proposed_start_date: @assignment.proposed_start_date, proposed_end_date: @assignment.proposed_end_date,
          proposed_work_days: @assignment.proposed_work_days,
          estimated_start_date: target.estimated_start_date, estimated_completion_date: target.estimated_completion_date
        }
      end
    end
  end
end
