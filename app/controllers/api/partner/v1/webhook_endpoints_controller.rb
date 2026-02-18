# frozen_string_literal: true

module Api
  module Partner
    module V1
      class WebhookEndpointsController < BaseController
        before_action :authorize_webhooks
        before_action :set_endpoint, only: [:show, :update, :destroy]

        # GET /api/partner/v1/webhook-endpoints
        def index
          endpoints = company_scope(WebhookEndpoint)

          # Filters
          endpoints = endpoints.where(status: params[:status]) if params[:status].present?

          # Cursor-based pagination
          endpoints = endpoints.order(:id)
          endpoints = endpoints.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          endpoints = endpoints.limit(limit + 1)

          records = endpoints.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |e| endpoint_json(e) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/webhook-endpoints/:id
        def show
          render json: { data: endpoint_json(@endpoint, detailed: true) }
        end

        # POST /api/partner/v1/webhook-endpoints
        def create
          endpoint = company_scope(WebhookEndpoint).new(endpoint_params)

          if endpoint.save
            # Show the secret on creation only
            json = endpoint_json(endpoint, detailed: true)
            json[:secret] = endpoint.secret
            render json: { data: json }, status: :created
          else
            render json: { error: "Validation failed", details: endpoint.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/webhook-endpoints/:id
        def update
          if @endpoint.update(endpoint_params)
            render json: { data: endpoint_json(@endpoint, detailed: true) }
          else
            render json: { error: "Validation failed", details: @endpoint.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/webhook-endpoints/:id
        def destroy
          @endpoint.destroy!
          render json: { data: { id: @endpoint.id, deleted: true } }
        end

        private

        def authorize_webhooks
          case action_name
          when "index", "show"
            authorize_permission!(:webhooks, :read)
          when "create"
            authorize_permission!(:webhooks, :create)
          when "update"
            authorize_permission!(:webhooks, :update)
          when "destroy"
            authorize_permission!(:webhooks, :delete)
          end
        end

        def set_endpoint
          @endpoint = company_scope(WebhookEndpoint).find(params[:id])
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
            json[:last_triggered_at] = endpoint.last_triggered_at&.iso8601
          end

          json
        end
      end
    end
  end
end
