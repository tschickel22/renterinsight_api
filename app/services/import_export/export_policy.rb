# frozen_string_literal: true

module ImportExport
  # Central gate for everything an export is allowed to do: which formats a
  # tenant may use, which fields may leave the building, how many exports a
  # user gets per day, how large one may be, and when the platform gets told.
  #
  # Deliberately NOT wired into RBAC. RBAC answers "may this user export?".
  # This answers "what may this tenant's exports contain?", which is a
  # commercial decision made per tenant in Platform Admin, not a role.
  class ExportPolicy
    SETTING_KEY   = 'export_settings'
    SETTING_SCOPE = 'Company'

    # Platform defaults. Any key may be overridden per tenant.
    DEFAULTS = {
      'allow_json'         => false,  # machine-ingestion format, off by default
      'daily_export_limit' => 3,      # exports per user per rolling 24h (0 = unlimited)
      'max_export_rows'    => 25_000, # hard cap on one export (0 = unlimited)
      'alert_row_threshold' => 1_000  # notify the platform above this (0 = never)
    }.freeze

    HUMAN_FORMATS   = %w[csv xlsx].freeze
    MACHINE_FORMATS = %w[json].freeze

    # Shown to the user at export time and stored verbatim on the job, so a
    # later dispute reads from the record instead of from memory.
    ACKNOWLEDGEMENT_TEXT = <<~TEXT.strip
      I confirm this export is for my organization's own business use, and that
      the exported data and the structure it is delivered in remain subject to
      our subscription agreement. This export is logged, watermarked, and
      attributable to my user account.
    TEXT

    # Columns that describe how the platform works rather than what the tenant
    # collected. The tenant owns their leads; they do not own our scoring
    # model, our integration keys, or our syndication internals. Excluded from
    # every export regardless of format.
    EXPORT_EXCLUDED_COLUMNS = %w[
      health_score
      health_score_updated_at
      last_activity_scored_at
      social_intent
      social_post_id
    ].freeze

    EXPORT_EXCLUDED_PATTERNS = [
      /\Achampion_/,       # Champion Homes integration internals
      /\Ascore_/,
      /_score\z/,
      /_score_/
    ].freeze

    class << self
      # Tenant overrides merged over platform defaults.
      def settings_for(company)
        stored = Setting.get(SETTING_SCOPE, company_id_of(company), SETTING_KEY)
        return DEFAULTS.dup unless stored.is_a?(Hash)

        DEFAULTS.merge(stored.stringify_keys.slice(*DEFAULTS.keys))
      end

      def json_allowed?(company)
        settings_for(company)['allow_json'] == true
      end

      def allowed_formats(company)
        json_allowed?(company) ? HUMAN_FORMATS + MACHINE_FORMATS : HUMAN_FORMATS.dup
      end

      def format_allowed?(company, format)
        allowed_formats(company).include?(format.to_s)
      end

      def daily_limit(company)
        settings_for(company)['daily_export_limit'].to_i
      end

      def row_cap(company)
        settings_for(company)['max_export_rows'].to_i
      end

      def alert_threshold(company)
        settings_for(company)['alert_row_threshold'].to_i
      end

      # Exports this user has started in the trailing 24 hours.
      def used_today(company, user)
        ExportJob.where(company_id: company_id_of(company), user_id: user.id)
                 .where(created_at: 24.hours.ago..)
                 .count
      end

      # nil when unlimited, otherwise how many the user has left.
      def remaining_today(company, user)
        limit = daily_limit(company)
        return nil if limit <= 0

        [limit - used_today(company, user), 0].max
      end

      def rate_limited?(company, user)
        remaining = remaining_today(company, user)
        !remaining.nil? && remaining <= 0
      end

      # True when a column must never appear in an export.
      def excluded_field?(key)
        key = key.to_s
        return true if EXPORT_EXCLUDED_COLUMNS.include?(key)

        EXPORT_EXCLUDED_PATTERNS.any? { |pattern| key.match?(pattern) }
      end

      # Applied both when listing fields to the UI and again in the Exporter,
      # so a hand-crafted request cannot select a field the UI never offered.
      def filter_fields(fields)
        fields.reject { |f| excluded_field?(f.is_a?(Hash) ? (f[:key] || f['key']) : f) }
      end

      def filter_keys(keys)
        Array(keys).map(&:to_s).reject { |k| excluded_field?(k) }
      end

      def new_watermark_token
        "EXP-#{SecureRandom.hex(8).upcase}"
      end

      private

      def company_id_of(company)
        company.respond_to?(:id) ? company.id : company.to_i
      end
    end
  end
end
