# frozen_string_literal: true

module Api
  module V1
    # In-app guidance: usage events and the person's own usage summary
    # (backlog E75). Every signed-in user may record and read their own usage;
    # there is nothing to authorize beyond being signed in to a company.
    class GuideController < ApplicationController
      before_action :set_company_scope

      # POST /api/v1/guide/events  { events: [{ kind, feature, route, at }] }
      # Only a person's use of their own company counts. Impersonated sessions
      # and platform admins switched into a dealer are not recorded, so looking
      # around a dealer's account never shows up as that dealer using it.
      def events
        return head(:no_content) if impersonating? || @company.id != current_user.company_id

        recorded = Guide::UsageRecorder.new(user: current_user, company_id: @company.id)
                                       .record(params[:events])
        render json: { recorded: recorded }
      end

      # GET /api/v1/guide/usage
      # What this person has used, most recent first.
      def usage
        rows = GuideFeatureUsage.where(user_id: current_user.id, company_id: @company.id)
                                .order(last_used_at: :desc)
                                .limit(500)
        render json: {
          features: rows.map do |u|
            { feature: u.feature_key, first_used_at: u.first_used_at, last_used_at: u.last_used_at, count: u.use_count }
          end
        }
      end
    end
  end
end
