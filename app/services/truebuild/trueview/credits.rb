# frozen_string_literal: true

module Truebuild
  module Trueview
    # When the Gemini account runs out of prepaid credits, every drawing and
    # outline is refused (HTTP 402). On staging, 2026-10-05, a morning of
    # testing turned that into 153 failed rows and a day's drawing limit
    # spent on nothing, with no word to anyone: the designer just stopped
    # changing. Now drawing pauses for PAUSE (buyers' visits queue nothing)
    # and the platform admins are told, at most every ALERT_EVERY.
    module Credits
      module_function

      PAUSE = 15.minutes
      ALERT_EVERY = 6.hours
      FLAG = 'truebuild:trueview:out_of_credits'

      def check!(res)
        return unless res.code == 402

        message = res.parsed_response.is_a?(Hash) ? res.parsed_response.dig('error', 'message') : nil
        out!(message.presence || res.body.to_s.first(300))
        raise Error, "Gemini 402: #{message || 'out of credits'}"
      end

      def out!(message)
        Rails.cache.write(FLAG, true, expires_in: PAUSE)
        return unless Rails.cache.write("#{FLAG}:alerted", true, expires_in: ALERT_EVERY, unless_exist: true)

        User.where(role: %w[platform_admin super_admin], deleted_at: nil).find_each do |user|
          NotificationService.create(
            recipient: user, notification_type: :system_alert, company_id: user.company_id, deliver_now: true,
            title: "TrueView stopped drawing: Gemini credits ran out (#{Rails.env})",
            message: "Google refused TrueView's drawings: #{message.to_s.first(200)} Add credits to the Gemini project in " \
                     'Google AI Studio (ai.studio, the project\'s billing). Drawing pauses and tries again every 15 minutes; ' \
                     'what failed meanwhile is drawn again on the next visit.',
            action_url: 'https://aistudio.google.com/', action_text: 'Open Google AI Studio'
          )
        rescue StandardError => e
          Rails.logger.warn("TrueView credits alert to #{user.id}: #{e.message}")
        end
      end

      def out? = Rails.cache.read(FLAG).present?
    end
  end
end
