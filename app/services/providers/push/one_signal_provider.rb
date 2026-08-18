# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Providers
  module Push
    # Thin OneSignal REST client.
    #
    # Targets the `external_id` alias rather than subscription ids, so one call
    # reaches every device a person has signed in on. Subscription-id targeting
    # is still supported for the "test this device" path, where the point is to
    # prove one specific handset works.
    class OneSignalProvider
      ENDPOINT = 'https://api.onesignal.com/notifications'
      TIMEOUT = 10

      class ConfigurationError < StandardError; end
      class DeliveryError < StandardError; end

      attr_reader :app, :config

      # app: 'staff' (DMS) or 'portal' (customer portal). Each is a separate
      # OneSignal app with its own credentials.
      def initialize(app: 'staff')
        @app = app.to_s
        @config = load_config
      end

      def configured?
        config[:app_id].present? && config[:api_key].present?
      end

      def enabled?
        configured? && PlatformSetting.push[:isEnabled] != false
      end

      # Returns { success:, external_id:, recipients:, invalid_external_ids:, invalid_subscription_ids: }
      def send_message(title:, body:, external_ids: [], subscription_ids: [], url: nil, data: {}, priority: 'normal', collapse_id: nil)
        validate_config!

        external_ids = Array(external_ids).compact.uniq
        subscription_ids = Array(subscription_ids).compact.uniq

        if external_ids.empty? && subscription_ids.empty?
          return { success: false, error: 'no_targets', recipients: 0 }
        end

        payload = build_payload(
          title: title,
          body: body,
          external_ids: external_ids,
          subscription_ids: subscription_ids,
          url: url,
          data: data,
          priority: priority,
          collapse_id: collapse_id
        )

        response = post(payload)
        interpret(response)
      rescue ConfigurationError
        raise
      rescue StandardError => e
        Rails.logger.error("[OneSignal] Push delivery failed (#{app}): #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        raise DeliveryError, "Push delivery failed: #{e.message}"
      end

      private

      def build_payload(title:, body:, external_ids:, subscription_ids:, url:, data:, priority:, collapse_id:)
        payload = {
          app_id: config[:app_id],
          headings: { en: title.to_s.truncate(64) },
          contents: { en: body.to_s.truncate(180) },
          data: data.presence || {}
        }

        if external_ids.any?
          payload[:include_aliases] = { external_id: external_ids }
          payload[:target_channel] = 'push'
        end
        payload[:include_subscription_ids] = subscription_ids if subscription_ids.any?

        # Natively routes this through the shell's web view, so it must be an
        # absolute app URL, not the bare in-app path we store on notifications.
        payload[:url] = url if url.present?

        # Urgent notifications are allowed to break through a dozing device.
        if %w[urgent high].include?(priority.to_s)
          payload[:priority] = 10
          payload[:ios_interruption_level] = priority.to_s == 'urgent' ? 'time-sensitive' : 'active'
        else
          payload[:priority] = 5
        end

        # Lets a second update about the same record replace the first in the
        # tray instead of stacking, which is most of what "don't spam me" means
        # in practice.
        payload[:collapse_id] = collapse_id.to_s.truncate(64) if collapse_id.present?

        payload
      end

      def post(payload)
        uri = URI.parse(ENDPOINT)

        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Key #{config[:api_key]}"
        request['Content-Type'] = 'application/json; charset=utf-8'
        request.body = payload.to_json

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        http.request(request)
      end

      def interpret(response)
        parsed = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          {}
        end

        errors = parsed['errors']

        unless response.is_a?(Net::HTTPSuccess)
          message = errors.is_a?(Array) ? errors.join(', ') : errors.to_s.presence || "HTTP #{response.code}"
          raise DeliveryError, "OneSignal rejected the push: #{message}"
        end

        # A 200 with no id means OneSignal accepted the request but found nobody
        # to send to. That is not an exception, but it is not a delivery either.
        result = {
          success: parsed['id'].present?,
          external_id: parsed['id'],
          recipients: parsed['recipients'].to_i,
          invalid_external_ids: [],
          invalid_subscription_ids: []
        }

        if errors.is_a?(Hash)
          result[:invalid_external_ids] = Array(errors['invalid_aliases'].is_a?(Hash) ? errors['invalid_aliases']['external_id'] : nil)
          result[:invalid_external_ids] |= Array(errors['invalid_external_user_ids'])
          result[:invalid_subscription_ids] = Array(errors['invalid_player_ids']) | Array(errors['invalid_subscription_ids'])
        end

        result[:error] = 'no_recipients' unless result[:success]
        result
      end

      def validate_config!
        return if configured?

        raise ConfigurationError,
              "OneSignal is not configured for the #{app} app (missing app id or API key)"
      end

      def load_config
        settings = PlatformSetting.push
        scoped = settings[app.to_sym] || {}

        {
          app_id: scoped[:appId].presence,
          api_key: scoped[:apiKey].presence
        }
      end
    end
  end
end
