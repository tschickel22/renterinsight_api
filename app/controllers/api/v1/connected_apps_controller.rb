# frozen_string_literal: true

module Api
  module V1
    # AI apps connected through the MCP connector. Everyone sees and can revoke
    # their own; company admins see and can revoke everyone's in the company.
    class ConnectedAppsController < ApplicationController
      before_action :set_company_scope

      ACTIVITY_LIMIT = 100
      SETTING_BOUNDS = { daily_record_limit: 50_000, hourly_change_limit: 1_000, daily_change_limit: 10_000 }.freeze

      def index
        grants = visible_grants.includes(:oauth_client, :user).order(created_at: :desc)
        calls = McpToolCall.where(oauth_grant_id: grants.map(&:id)).where(created_at: 30.days.ago..)
                           .group(:oauth_grant_id).count

        render json: {
          module_enabled: Oauth::AccessPolicy.module_enabled?(@company),
          mcp_url: Oauth::Config.resource(request),
          can_manage_all: admin?,
          can_connect: Oauth::AccessPolicy.permitted?(current_user, @company),
          can_allow_changes: Oauth::AccessPolicy.changes_permitted?(current_user, @company),
          **limits,
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
        changes = McpChange.where(mcp_tool_call_id: rows.map(&:id)).order(:id).group_by(&:mcp_tool_call_id)

        render json: {
          today: { calls: today.count, records: today.sum(:result_count), denied: today.where(status: 'denied').count },
          calls: rows.map do |c|
            {
              id: c.id, at: c.created_at, user: names[c.user_id], app: c.client_name, tool: c.tool_name,
              arguments: c.arguments, status: c.status, records: c.result_count, error: c.error_message,
              changes: Array(changes[c.id]).map { |ch| change_json(ch) }
            }
          end
        }
      end

      # POST /api/v1/connected-apps/changes/:change_id/undo
      def undo_change
        change = McpChange.where(company_id: @company.id).find_by(id: params[:change_id])
        return render json: { error: 'Not found' }, status: :not_found unless change && may_undo?(change.user_id)

        result = McpTools::Undo.undo!(change, by: current_user)
        log_undo(1, result.undone? ? 1 : 0)
        render json: { undone: result.undone?, message: result.message, change: change_json(change.reload) }
      end

      # POST /api/v1/connected-apps/:id/undo_recent { hours }
      # Everything one connection changed in the last N hours, newest first,
      # for stopping a runaway session in one go.
      def undo_recent
        grant = OauthGrant.where(company_id: @company.id).find_by(id: params[:id])
        return render json: { error: 'Not found' }, status: :not_found unless grant && may_undo?(grant.user_id)

        hours = params[:hours].to_i.clamp(1, 72)
        changes = McpChange.not_undone.where(oauth_grant_id: grant.id, created_at: hours.hours.ago..).order(id: :desc)
        results = changes.map { |ch| [ch, McpTools::Undo.undo!(ch, by: current_user)] }
        undone = results.count { |_, r| r.undone? }
        log_undo(results.size, undone, grant)

        render json: {
          undone: undone, skipped: results.size - undone,
          skipped_changes: results.reject { |_, r| r.undone? }.map { |ch, r| change_json(ch).merge(message: r.message) }
        }
      end

      # PUT /api/v1/connected-apps/settings
      # { daily_record_limit, hourly_change_limit, daily_change_limit }, any subset.
      def update_settings
        return unless authorize_action!('company_settings', 'update')

        updates = {}
        SETTING_BOUNDS.each do |key, max|
          next unless params.key?(key)

          value = Integer(params[key].to_s, exception: false)
          unless value && value.between?(0, max)
            return render json: { error: "#{key.to_s.tr('_', ' ').capitalize} must be a whole number from 0 to #{max}." },
                          status: :unprocessable_entity
          end

          updates[key.to_s] = value
        end
        return render json: { error: 'Nothing to change.' }, status: :unprocessable_entity if updates.empty?

        settings = (Setting.get('Company', @company.id, 'mcp_settings', {}) || {}).merge(updates)
        Setting.set('Company', @company.id, 'mcp_settings', settings)
        ActivityLogService.log(company: @company, user: current_user, action: 'updated', module_name: 'ai_connector',
                               description: "AI connector limits set: #{updates.map { |k, v| "#{k.tr('_', ' ')} #{v}" }.join(', ')}")
        render json: limits
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

      def limits
        ctx = McpTools::Context.new(user: current_user, company: @company, grant: nil)
        { daily_record_limit: ctx.daily_record_limit, hourly_change_limit: ctx.hourly_change_limit,
          daily_change_limit: ctx.daily_change_limit }
      end

      def change_json(change)
        { id: change.id, description: McpTools::Undo.describe(change), undone_at: change.undone_at,
          undo_note: change.undo_note }
      end

      # Admins undo anyone's; a person undoes their own AI app's changes.
      def may_undo?(user_id)
        admin? || user_id == current_user.id
      end

      def log_undo(attempted, undone, grant = nil)
        ActivityLogService.log(
          company: @company, user: current_user, action: 'undone', module_name: 'ai_connector',
          description: "Undid #{undone} of #{attempted} AI connector change#{'s' unless attempted == 1}" \
                       "#{grant ? " by #{grant.oauth_client.client_name} for #{grant.user.full_name}" : ''}",
          metadata: { oauth_grant_id: grant&.id }
        )
      end

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
