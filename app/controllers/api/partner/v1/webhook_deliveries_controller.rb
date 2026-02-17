# frozen_string_literal: true

module Api
  module Partner
    module V1
      class WebhookDeliveriesController < BaseController
        before_action -> { authorize_permission!(:webhooks, :read) }

        # GET /api/partner/v1/webhook-endpoints/:webhook_endpoint_id/deliveries
        def index
          endpoint = company_scope(WebhookEndpoint).find(params[:webhook_endpoint_id])
          deliveries = endpoint.webhook_deliveries

          # Filters
          deliveries = deliveries.where(event: params[:event]) if params[:event].present?
          deliveries = deliveries.successful if params[:status] == "successful"
          deliveries = deliveries.failed if params[:status] == "failed"
          deliveries = deliveries.pending if params[:status] == "pending"

          # Cursor-based pagination (newest first for deliveries)
          deliveries = deliveries.order(id: :desc)
          deliveries = deliveries.where("id < ?", params[:before].to_i) if params[:before].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          deliveries = deliveries.limit(limit + 1)

          records = deliveries.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |d| delivery_json(d) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/webhook-endpoints/:webhook_endpoint_id/deliveries/:id
        def show
          endpoint = company_scope(WebhookEndpoint).find(params[:webhook_endpoint_id])
          delivery = endpoint.webhook_deliveries.find(params[:id])

          render json: { data: delivery_json(delivery, detailed: true) }
        end

        private

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
end
