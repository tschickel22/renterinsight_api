# frozen_string_literal: true

module Api
  module V1
    # AI apps connected through the MCP connector. Everyone sees and can revoke
    # their own; company admins see and can revoke everyone's in the company.
    class ConnectedAppsController < ApplicationController
      before_action :set_company_scope

      ACTIVITY_LIMIT = 100
      MAX_DAILY_RECORD_LIMIT = 50_000

      def index
        grants = visible_grants.includes(:oauth_client, :user).order(created_at: :desc)
        calls = McpToolCall.where(oauth_grant_id: grants.map(&:id)).where(created_at: 30.days.ago..)
                           .group(:oauth_grant_id).count

        render json: {
          module_enabled: Oauth::AccessPolicy.module_enabled?(@company),
          mcp_url: Oauth::Config.resource(request),
          can_manage_all: admin?,
          daily_record_limit: McpTools::Context.new(user: current_user, company: @company, grant: nil).daily_record_limit,
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

      # GET /api/v1/connected-apps/activity
      # What the AI apps did: the newest tool calls, company-wide for admins
      # and the user's own otherwise. This is the oversight view for a new way
      # data can leave the system.
      def activity
        calls = McpToolCall.where(company_id: @company.id)
        calls = calls.where(user_id: current_user.id) unless admin?
        rows = calls.order(created_at: :desc).limit(ACTIVITY_LIMIT).to_a
        names = @company.users.where(id: rows.map(&:user_id).uniq).to_h { |u| [u.id, u.full_name] }
        today = calls.where(created_at: Time.current.beginning_of_day..)

        render json: {
          today: { calls: today.count, records: today.sum(:result_count), denied: today.where(status: 'denied').count },
          calls: rows.map do |c|
            {
              id: c.id, at: c.created_at, user: names[c.user_id], app: c.client_name, tool: c.tool_name,
              arguments: c.arguments, status: c.status, records: c.result_count, error: c.error_message
            }
          end
        }
      end

      # PUT /api/v1/connected-apps/settings { daily_record_limit }
      def update_settings
        return unless authorize_action!('company_settings', 'update')

        limit = Integer(params[:daily_record_limit].to_s, exception: false)
        unless limit && limit.between?(0, MAX_DAILY_RECORD_LIMIT)
          return render json: { error: "Daily record limit must be a whole number from 0 to #{MAX_DAILY_RECORD_LIMIT}." },
                        status: :unprocessable_entity
        end

        settings = (Setting.get('Company', @company.id, 'mcp_settings', {}) || {}).merge('daily_record_limit' => limit)
        Setting.set('Company', @company.id, 'mcp_settings', settings)
        ActivityLogService.log(company: @company, user: current_user, action: 'updated', module_name: 'ai_connector',
                               description: "AI connector daily record limit set to #{limit}")
        render json: { daily_record_limit: limit }
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
