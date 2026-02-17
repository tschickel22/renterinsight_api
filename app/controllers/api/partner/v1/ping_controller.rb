# frozen_string_literal: true

module Api
  module Partner
    module V1
      class PingController < BaseController
        def show
          render json: {
            status: "ok",
            api_version: "v1",
            company: current_company.name,
            api_key: current_api_key.name,
            timestamp: Time.current.iso8601
          }
        end
      end
    end
  end
end
