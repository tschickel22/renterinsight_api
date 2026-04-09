module Api
  module V1
    class WorkflowFieldOptionsController < ApplicationController
      include RbacAuthorization
      before_action :set_company_scope
      rbac_resource :workflow_automation, read_actions: [:index]

      def index
        entity_type = params[:entity_type].to_s

        unless WorkflowFieldMetadata::SUPPORTED_TYPES.include?(entity_type)
          return render(
            json: {
              error: "Unsupported entity_type",
              supported: WorkflowFieldMetadata::SUPPORTED_TYPES
            },
            status: :bad_request
          )
        end

        render json: WorkflowFieldMetadata.for(entity_type)
      end
    end
  end
end
