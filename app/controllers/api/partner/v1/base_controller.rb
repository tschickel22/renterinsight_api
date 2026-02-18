# frozen_string_literal: true

module Api
  module Partner
    module V1
      class BaseController < ActionController::API
        include ApiKeyAuthentication

        rescue_from ActiveRecord::RecordNotFound do |e|
          render json: { error: "Resource not found" }, status: :not_found
        end

        rescue_from ActiveRecord::RecordInvalid do |e|
          render json: { error: e.message, details: e.record&.errors&.full_messages }, status: :unprocessable_entity
        end

        rescue_from ActionController::ParameterMissing do |e|
          render json: { error: "Missing parameter: #{e.param}" }, status: :bad_request
        end

        private

        # Company-scoped queries - all partner API data is scoped to the API key's company
        def company_scope(model)
          model.where(company_id: current_company_id)
        end
      end
    end
  end
end
