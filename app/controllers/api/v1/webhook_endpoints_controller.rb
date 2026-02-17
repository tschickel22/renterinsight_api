# frozen_string_literal: true

module Api
  module V1
    class WebhookEndpointsController < ApplicationController
      before_action :set_company_scope
      before_action :set_endpoint, only: [:show, :update, :destroy, :test]

      # GET /api/v1/webhook-endpoints
      def index
        return unless authorize_action!("webhooks", "read")

        endpoints = @company.webhook_endpoints.order(created_at: :desc)

        # Filter
        endpoints = endpoints.where(status: params[:status]) if params[:status].present?

        render json: {
          webhook_endpoints: endpoints.map { |e| endpoint_json(e) },
          meta: {
            total: endpoints.count,
            company_id: @company.id
          }
        }
      end

      # GET /api/v1/webhook-endpoints/:id
      def show
        return unless authorize_action!("webhooks", "read")

        recent_deliveries = @endpoint.webhook_deliveries
          .order(created_at: :desc)
          .limit(10)

        render json: {
          webhook_endpoint: endpoint_json(@endpoint, detailed: true),
          recent_deliveries: recent_deliveries.map { |d| delivery_summary_json(d) }
        }
      end

      # POST /api/v1/webhook-endpoints
      def create
        return unless authorize_action!("webhooks", "create")

        endpoint = @company.webhook_endpoints.new(endpoint_params)

        if endpoint.save
          json = endpoint_json(endpoint, detailed: true)
          json[:secret] = endpoint.secret

          render json: {
            webhook_endpoint: json,
            message: "Webhook endpoint created. Save the signing secret — use it to verify payloads."
          }, status: :created
        else
          render json: { errors: endpoint.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/webhook-endpoints/:id
      def update
        return unless authorize_action!("webhooks", "update")

        if @endpoint.update(endpoint_params)
          render json: {
            webhook_endpoint: endpoint_json(@endpoint, detailed: true),
            message: "Webhook endpoint updated successfully"
          }
        else
          render json: { errors: @endpoint.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/webhook-endpoints/:id
      def destroy
        return unless authorize_action!("webhooks", "delete")

        @endpoint.destroy!
        render json: { message: "Webhook endpoint deleted" }
      end

      # POST /api/v1/webhook-endpoints/:id/test
      def test
        return unless authorize_action!("webhooks", "update")

        unless @endpoint.active?
          render json: { error: "Cannot test an inactive endpoint" }, status: :unprocessable_entity
          return
        end

        test_payload = WebhookService.build_envelope("test.ping", {
          message: "This is a test webhook from Renter Insight",
          triggered_by: current_user.email,
          timestamp: Time.current.iso8601
        })

        delivery = WebhookDelivery.create!(
          webhook_endpoint: @endpoint,
          event: "test.ping",
          payload: test_payload
        )

        # Deliver synchronously so we can return the result
        WebhookDeliveryJob.perform_now(delivery.id)
        delivery.reload

        render json: {
          message: delivery.successful? ? "Test webhook delivered successfully" : "Test webhook failed",
          delivery: {
            id: delivery.id,
            response_code: delivery.response_code,
            response_body: delivery.response_body&.truncate(500),
            successful: delivery.successful?,
            delivered_at: delivery.delivered_at&.iso8601
          }
        }
      end

      private

      def set_endpoint
        @endpoint = @company.webhook_endpoints.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Webhook endpoint not found" }, status: :not_found
      end

      def endpoint_params
        params.permit(:url, :status, events: [])
      end

      def endpoint_json(endpoint, detailed: false)
        json = {
          id: endpoint.id,
          url: endpoint.url,
          events: endpoint.events,
          status: endpoint.status,
          failure_count: endpoint.failure_count,
          created_at: endpoint.created_at&.iso8601,
          updated_at: endpoint.updated_at&.iso8601
        }

        if detailed
          json.merge!(
            last_triggered_at: endpoint.last_triggered_at&.iso8601,
            available_events: WebhookService::EVENTS
          )
        end

        json
      end

      def delivery_summary_json(delivery)
        {
          id: delivery.id,
          event: delivery.event,
          response_code: delivery.response_code,
          attempts: delivery.attempts,
          successful: delivery.successful?,
          delivered_at: delivery.delivered_at&.iso8601,
          created_at: delivery.created_at&.iso8601
        }
      end
    end
  end
end
