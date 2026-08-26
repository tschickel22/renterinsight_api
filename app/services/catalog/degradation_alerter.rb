# frozen_string_literal: true

module Catalog
  # Fires an alert when a run degrades (a tracked field dropped below threshold)
  # or fails outright. Channels match existing infra: in-app + email via
  # NotificationService (system_alert type). No Slack integration exists in this
  # codebase, so email is the external channel.
  #
  # Recipients: all platform admins (the only people who manage Surface B).
  class DegradationAlerter
    def self.call(source:, run:)
      new(source, run).call
    end

    def initialize(source, run)
      @source = source
      @run    = run
    end

    def call
      Rails.logger.warn "[Catalog::DegradationAlerter] #{@source.name} run ##{@run.id} " \
                        "status=#{@run.status} degraded=#{@run.degraded}"

      recipients.find_each do |user|
        NotificationService.create(
          recipient:         user,
          notification_type: :system_alert,
          title:             title,
          message:           message,
          # system_alert is urgent by default, which is right for a scraper that
          # broke and wrong for a manufacturer who published a page without
          # photos. An alert that cannot be acted on should not read like one, or
          # the ones that can stop being read.
          priority:          diagnosis&.upstream? ? 'normal' : nil,
          action_url:        "/admin/catalog-sources/#{@source.id}",
          action_text:       'View health',
          deliver_now:       true,
          company_id:        user.company_id,
          metadata:          { catalog_source_id: @source.id, scrape_run_id: @run.id,
                               verdict: diagnosis&.verdict }.compact
        )
      end
    end

    private

    def recipients
      User.where(role: %w[platform_admin super_admin], deleted_at: nil)
    end

    def title
      if @run.status == 'failed'
        "Catalog source FAILED: #{@source.name}"
      else
        "Catalog source degraded: #{@source.name}"
      end
    end

    def message
      return "Run ##{@run.id} failed: #{failure_reason}" if @run.status == 'failed'

      threshold = @source.extraction_threshold.to_f
      fields = @run.degraded_fields(threshold).map do |field, rate|
        "#{field} #{(rate.to_f * 100).round}% (threshold #{(threshold * 100).round}%)"
      end
      parts = ["Run ##{@run.id} degraded. Below-threshold fields: #{fields.join(', ')}."]
      parts << 'Existing populated data was preserved (not overwritten with blanks).'

      # Whose problem it is, said before the detail, because that is the only
      # part that decides whether to do anything.
      if diagnosis&.summary.present?
        parts.unshift(diagnosis.summary)
        parts << diagnosis.detail
      end

      # The pages to send the manufacturer, so chasing it does not start with
      # working out which ones they were.
      parts << "Affected pages: #{affected_urls.join(', ')}" if affected_urls.any?

      parts.join(' ')
    end

    # Capped: an alert is a message, not a report, and a source that loses a
    # field across two hundred models does not become clearer at page fifty.
    MAX_URLS = 5

    def affected_urls
      @affected_urls ||= Array(@run.error_log)
                         .filter_map { |e| e.is_a?(Hash) ? e['url'] : nil }
                         .uniq.first(MAX_URLS)
    rescue StandardError
      []
    end

    def diagnosis
      return @diagnosis if defined?(@diagnosis)

      @diagnosis = DegradationDiagnosis.call(
        source: @source, run: @run, threshold: @source.extraction_threshold.to_f
      )
    rescue StandardError => e
      Rails.logger.warn("[Catalog::DegradationAlerter] diagnosis failed: #{e.message}")
      @diagnosis = nil
    end

    def failure_reason
      Array(@run.error_log).first&.dig('message') || 'unknown error'
    end
  end
end
