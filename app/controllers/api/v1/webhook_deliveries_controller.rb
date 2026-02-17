# frozen_string_literal: true

module Api
  module V1
    class WebhookDeliveriesController < ApplicationController
      before_action :set_company_scope
      before_action :set_endpoint

      # GET /api/v1/webhook-endpoints/:webhook_endpoint_id/deliveries
      def index
        return unless authorize_action!("webhooks", "read")

        deliveries = @endpoint.webhook_deliveries

        # Filters
        deliveries = deliveries.where(event: params[:event]) if params[:event].present?
        deliveries = deliveries.successful if params[:status] == "successful"
        deliveries = deliveries.failed if params[:status] == "failed"
        deliveries = deliveries.pending if params[:status] == "pending"

        # Pagination
        page = [params.fetch(:page, 1).to_i, 1].max
        per_page = [params.fetch(:per_page, 25).to_i, 100].min
        total = deliveries.count

        deliveries = deliveries
          .order(created_at: :desc)
          .offset((page - 1) * per_page)
          .limit(per_page)

        render json: {
          deliveries: deliveries.map { |d| delivery_json(d) },
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end

      # GET /api/v1/webhook-endpoints/:webhook_endpoint_id/deliveries/:id
      def show
        return unless authorize_action!("webhooks", "read")

        delivery = @endpoint.webhook_deliveries.find(params[:id])

        render json: {
          delivery: delivery_json(delivery, detailed: true)
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Delivery not found" }, status: :not_found
      end

      private

      def set_endpoint
        @endpoint = @company.webhook_endpoints.find(params[:webhook_endpoint_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Webhook endpoint not found" }, status: :not_found
      end

      def delivery_json(delivery, detailed: false)
        json = {
          id: delivery.id,
          event: delivery.event,
          response_code: delivery.response_code,
          attempts: delivery.attempts,
          successful: delivery.successful?,
          delivered_at: delivery.delivered_at&.iso8601,
          created_at: delivery.created_at&.iso8601
        }

        if detailed
          json.merge!(
            payload: delivery.payload,
            response_body: delivery.response_body
          )
        end

        json
      end
    end
  end
end
