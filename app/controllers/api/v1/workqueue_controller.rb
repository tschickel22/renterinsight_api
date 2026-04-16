# frozen_string_literal: true

module Api
  module V1
    class WorkqueueController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/workqueue/summary
      def summary
        service = WorkqueueService.new(company: @company, user: current_user)
        render json: { groups: service.summary }
      end

      # GET /api/v1/workqueue/items?queue=leads_mine&page=1&per_page=50&search=...
      def items
        queue_id = params[:queue].to_s
        unless WorkqueueService::QUEUES.key?(queue_id)
          return render json: { error: "Unknown queue: #{queue_id}" }, status: :bad_request
        end

        service = WorkqueueService.new(
          company:  @company,
          user:     current_user,
          queue_id: queue_id,
          filters:  params.permit(:search, :sort_by, :sort_order).to_h.symbolize_keys,
          page:     params[:page] || 1,
          per_page: params[:per_page] || 50,
        )

        render json: service.items
      end
    end
  end
end
