# frozen_string_literal: true

module Truebuild
  module Trueview
    # When the Gemini account runs out of prepaid credits, every drawing and
    # outline is refused (HTTP 402). On staging, 2026-10-05, a morning of
    # testing turned that into 153 failed rows and a day's drawing limit
    # spent on nothing, with no word to anyone: the designer just stopped
    # changing. Now drawing pauses for PAUSE (buyers' visits queue nothing)
    # and the platform admins are told, at most every ALERT_EVERY.
    #
    # The same for Claude, which checks every drawing and outline: on
    # 2026-10-15 production's Anthropic spend limit ran out mid run, 142
    # drawings were shown to buyers unchecked and 88 more were marked failed.
    module Credits
      module_function

      class Out < Error; end

      PAUSE = 15.minutes
      ALERT_EVERY = 6.hours
      FLAG = 'truebuild:trueview:out_of_credits'

      def check!(res)
        return unless res.code == 402

        message = res.parsed_response.is_a?(Hash) ? res.parsed_response.dig('error', 'message') : nil
        out!(message.presence || res.body.to_s.first(300))
        raise Out, "Gemini 402: #{message || 'out of credits'}"
      end

      # A Claude call refused for credits: pauses like a Gemini 402, and is
      # raised again so the drawing waits rather than passing unchecked.
      def claude_out!(error)
        out!(error.message, provider: :claude)
        raise error
      end

      # Either account out of credits.
      def error?(error) = error.is_a?(Out) || error.is_a?(Catalog::PriceBooks::ClaudeClient::OutOfCredits)

      ALERTS = {
        gemini: { name: 'Gemini', where: 'Add credits to the Gemini project in Google AI Studio (ai.studio, the project\'s billing).',
                  url: 'https://aistudio.google.com/', text: 'Open Google AI Studio' },
        claude: { name: 'Claude', where: 'Add credits or raise the spend limit in the Anthropic Console (Settings, Limits).',
                  url: 'https://console.anthropic.com/settings/limits', text: 'Open the Anthropic Console' }
      }.freeze

      def out!(message, provider: :gemini)
        Rails.cache.write(FLAG, true, expires_in: PAUSE)
        return unless Rails.cache.write("#{FLAG}:alerted:#{provider}", true, expires_in: ALERT_EVERY, unless_exist: true)

        alert = ALERTS.fetch(provider)
        User.where(role: %w[platform_admin super_admin], deleted_at: nil).find_each do |user|
          NotificationService.create(
            recipient: user, notification_type: :system_alert, company_id: user.company_id, deliver_now: true,
            title: "TrueView stopped drawing: #{alert[:name]} credits ran out (#{Rails.env})",
            message: "#{alert[:name]} refused TrueView's work: #{message.to_s.first(200)} #{alert[:where]} Drawing pauses and " \
                     'tries again every 15 minutes; a factory run picks up what failed meanwhile, and a buyer\'s ' \
                     'drawing is drawn again on the next visit.',
            action_url: alert[:url], action_text: alert[:text]
          )
        rescue StandardError => e
          Rails.logger.warn("TrueView credits alert to #{user.id}: #{e.message}")
        end
      end

      def out? = Rails.cache.read(FLAG).present?
    end
  end
end
