# frozen_string_literal: true

module Api
  module Partner
    module V1
      class WebhookEventsController < BaseController
        # GET /api/partner/v1/webhook-events
        # Lists all available webhook events partners can subscribe to
        def index
          render json: {
            data: WebhookService::EVENTS.map do |event|
              resource, action = event.split(".")
              { event: event, resource: resource, action: action }
            end
          }
        end
      end
    end
  end
end
