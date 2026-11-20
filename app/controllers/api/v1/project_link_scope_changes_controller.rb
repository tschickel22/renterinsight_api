# frozen_string_literal: true

# E106, installer side: answer a dealer's scope change with "no charge". A
# change order answers it through POST /project_links/:id/changes with
# scope_change_id.
module Api
  module V1
    class ProjectLinkScopeChangesController < ApplicationController
      before_action :set_company_scope

      # POST /api/v1/project_link_scope_changes/:id/no_charge
      def no_charge
        return unless authorize_action!('deals', 'update')

        change = ProjectLinkScopeChange.joins(:project_link)
                                       .where(project_links: { installer_company_id: @company.id }).find_by(id: params[:id])
        return render json: { error: 'Not found' }, status: :not_found unless change

        ProjectLinkScope.new(actor: current_user).no_charge!(change, @company)
        render json: { scope_change: { id: change.id, status: change.status } }
      rescue ProjectLinkScope::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end
