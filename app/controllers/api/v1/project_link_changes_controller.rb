# frozen_string_literal: true

module Api
  module V1
    # The dealer approves or declines a price request or change order on a
    # handed-off job; the installer can withdraw one still waiting (E68 step 6).
    class ProjectLinkChangesController < ApplicationController
      include LinkPricingJson

      before_action :set_company_scope
      before_action :set_change

      # POST /api/v1/project_link_changes/:id/approve
      def approve
        return unless authorize_action!('deals', 'update')

        render json: { change: link_change_json(service.approve_change!(@change)) }
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/project_link_changes/:id/decline { reason }
      def decline
        return unless authorize_action!('deals', 'update')

        render json: { change: link_change_json(service.decline_change!(@change, reason: params[:reason])) }
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/project_link_changes/:id/withdraw
      def withdraw
        return unless authorize_action!('deals', 'update')

        render json: { change: link_change_json(service.withdraw_change!(@change)) }
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def service
        ProjectLinkService.new(@company, actor: current_user)
      end

      # Only a request on a job this company sent or runs.
      def set_change
        @change = ProjectLinkChange.joins(:project_link)
                                   .where(project_links: { dealer_company_id: @company.id })
                                   .or(ProjectLinkChange.joins(:project_link).where(project_links: { installer_company_id: @company.id }))
                                   .find_by(id: params[:id])
        render json: { error: 'Not found' }, status: :not_found unless @change
      end
    end
  end
end
