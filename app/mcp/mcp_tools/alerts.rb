# frozen_string_literal: true

module McpTools
  # Tells a company's admins when an AI app's use looks like more than normal
  # work: a person hit the daily record limit, or their AI app keeps asking
  # for things it is refused. Either is how a bulk export attempt would show
  # up (Company 17 took 9,703 leads the day it left), so the people who can
  # disconnect the app hear about it the same day.
  #
  # One alert per person, per kind, per day. In-app notifications only: email
  # and SMS follow each admin's preferences, which this type has never had.
  module Alerts
    REFUSALS_PER_HOUR = 10

    module_function

    def after_call(ctx, status:, limit_reached:)
      case limit_reached
      when :records
        notify(ctx, 'limit_reached',
               "#{ctx.user.full_name}'s AI app (#{app_name(ctx)}) reached the daily limit of " \
               "#{ctx.daily_record_limit} records. Review the activity and disconnect it if that was not expected.")
      when :changes
        notify(ctx, 'change_limit_reached',
               "#{ctx.user.full_name}'s AI app (#{app_name(ctx)}) reached its limit on changes. Review what it " \
               'changed under Settings, Integrations, AI Apps, and undo it there if that was not expected.')
      end
      if limit_reached.nil? && status == 'denied' && recent_refusals(ctx) >= REFUSALS_PER_HOUR
        notify(ctx, 'repeated_refusals',
               "#{ctx.user.full_name}'s AI app (#{app_name(ctx)}) was refused #{REFUSALS_PER_HOUR} or more times " \
               'in the last hour. It may be reaching for records this person cannot see.')
      end
    rescue StandardError => e
      Rails.logger.error("[McpTools::Alerts] #{e.class}: #{e.message}")
    end

    def recent_refusals(ctx)
      McpToolCall.where(user_id: ctx.user.id, company_id: ctx.company.id, status: 'denied', created_at: 1.hour.ago..).count
    end

    def app_name(ctx)
      ctx.grant&.oauth_client&.client_name || 'an AI app'
    end

    def notify(ctx, kind, message)
      key = "#{kind}:#{ctx.user.id}:#{Date.current.iso8601}"
      return if Notification.where(company_id: ctx.company.id, notification_type: 'ai_connector_alert')
                            .where("metadata->>'alert_key' = ?", key).exists?

      admins(ctx.company).each do |admin|
        NotificationService.create(
          recipient: admin, notification_type: :ai_connector_alert, actor: ctx.user, message: message,
          company_id: ctx.company.id, location_id: nil, push: false,
          action_url: '/settings?tab=ai-apps', action_text: 'Review AI activity',
          metadata: { 'alert_key' => key, 'user_id' => ctx.user.id, 'oauth_grant_id' => ctx.grant&.id }
        )
      end
    end

    def admins(company)
      company.users.active.to_a.select(&:effective_admin?)
    end
  end
end
