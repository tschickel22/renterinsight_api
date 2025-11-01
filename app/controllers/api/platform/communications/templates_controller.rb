# frozen_string_literal: true

module Api
  module Platform
    module Communications
      class TemplatesController < ApplicationController
        # GET /api/platform/communications/templates
        def index
          # Stub endpoint - returns empty templates array
          # TODO: Implement full template management system
          render json: {
            success: true,
            templates: []
          }
        end
      end
    end
  end
end
