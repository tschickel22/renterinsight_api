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
          action_url:        "/admin/catalog-sources/#{@source.id}",
          action_text:       'View health',
          deliver_now:       true,
          company_id:        user.company_id,
          metadata:          { catalog_source_id: @source.id, scrape_run_id: @run.id }
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
      "Run ##{@run.id} degraded. Below-threshold fields: #{fields.join(', ')}. " \
        'Existing populated data was preserved (not overwritten with blanks).'
    end

    def failure_reason
      Array(@run.error_log).first&.dig('message') || 'unknown error'
    end
  end
end
