# frozen_string_literal: true

module Api
  module V1
    class HealthController < ApplicationController
      # GET /api/v1/health/ping - lightweight auth check
      def ping
        render json: { ok: true, user_id: current_user&.id }, status: :ok
      end
    end
  end
end
