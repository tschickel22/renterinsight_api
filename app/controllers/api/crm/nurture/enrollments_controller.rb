module Api
  module Crm
    module Nurture
      class EnrollmentsController < ApplicationController
        # GET /api/crm/nurture/enrollments
        def index
          render json: []
        end

        # POST /api/crm/nurture/enrollments/bulk
        def bulk
          payload = params.to_unsafe_h
          list = payload['enrollments'] || payload['items'] || []
          render json: list
        end
      end
    end
  end
end
