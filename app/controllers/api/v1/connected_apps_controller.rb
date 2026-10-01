# frozen_string_literal: true

module Api
  module V1
    # AI apps connected through the MCP connector. Everyone sees and can revoke
    # their own; company admins see and can revoke everyone's in the company.
    class ConnectedAppsController < ApplicationController
      before_action :set_company_scope

      def index
        grants = visible_grants.includes(:oauth_client, :user).order(created_at: :desc)
        calls = McpToolCall.where(oauth_grant_id: grants.map(&:id)).where(created_at: 30.days.ago..)
                           .group(:oauth_grant_id).count

        render json: {
          module_enabled: Oauth::AccessPolicy.module_enabled?(@company),
          mcp_url: Oauth::Config.resource(request),
          can_manage_all: admin?,
          connections: grants.map do |g|
            {
              id: g.id,
              app_name: g.oauth_client.client_name,
              user: { id: g.user_id, name: g.user.full_name, email: g.user.email },
              is_mine: g.user_id == current_user.id,
              scopes: g.scope_list,
              connected_at: g.created_at,
              last_used_at: g.last_used_at,
              calls_last_30_days: calls[g.id] || 0
            }
          end
        }
      end

      def destroy
        grant = visible_grants.find_by(id: params[:id])
        return render json: { error: 'Not found' }, status: :not_found unless grant

        grant.revoke!(by_user: original_user)
        ActivityLogService.log(
          company: @company, user: current_user, action: 'disconnected', module_name: 'ai_connector',
          description: "Disconnected #{grant.oauth_client.client_name} for #{grant.user.full_name}",
          metadata: { oauth_grant_id: grant.id }
        )
        render json: { revoked: true }
      end

      private

      def admin?
        current_user.effective_admin? || original_user&.platform_admin? || original_user&.super_admin?
      end

      def visible_grants
        scope = OauthGrant.active.where(company_id: @company.id)
        admin? ? scope : scope.where(user_id: current_user.id)
      end
    end
  end
end
