module Api
  module Crm
    module Nurture
      class SequencesController < ApplicationController
        # GET /api/crm/nurture/sequences
        def index
          render json: []
        end

        # POST /api/crm/nurture/sequences/bulk
        def bulk
          payload = params.to_unsafe_h
          list = payload['sequences'] || payload['items'] || []
          render json: list
        end
      end
    end
  end
end
