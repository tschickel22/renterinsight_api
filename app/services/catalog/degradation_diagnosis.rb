# frozen_string_literal: true

module Catalog
  # Whether a degraded run is our problem or the manufacturer's.
  #
  # The alert used to state the drop and stop, which left the same investigation
  # to be done by hand every time: open the failing pages, open a page from a
  # source that still works, and see whether the field is missing from the site
  # or missing from our parsing. That is a mechanical comparison, and the data to
  # do it is already stored.
  #
  # The tell is other sources on the same adapter. Tru Mini dropped images to 0%
  # in run 126 while Tru Homes, same adapter and same template, was still at 92%.
  # An extractor that works on twelve pages and not on two is not broken; those
  # two pages are. In that case there is nothing to build and the answer is to
  # wait for the manufacturer, which is exactly what the alert should say instead
  # of implying an outage.
  #
  # The opposite reading matters just as much: when every source on an adapter
  # loses the same field at once, the site changed under us and it is ours to fix.
  class DegradationDiagnosis
    Result = Struct.new(:verdict, :summary, :detail, keyword_init: true) do
      # Nothing to do but wait, so the alert should not read as an incident.
      def upstream? = verdict == :upstream
    end

    # How long a sibling run stays relevant. Sources run weekly, so two weeks
    # covers a missed run without comparing against something long stale.
    SIBLING_WINDOW = 14.days

    def self.call(source:, run:, threshold:)
      new(source, run, threshold).call
    end

    def initialize(source, run, threshold)
      @source = source
      @run = run
      @threshold = threshold.to_f
    end

    def call
      fields = @run.degraded_fields(@threshold).keys.map(&:to_s)
      return inconclusive('no fields below threshold') if fields.empty?

      healthy = fields.index_with { |field| siblings_still_extracting(field) }
      working = healthy.select { |_, sources| sources.any? }

      return upstream(working) if working.any? && working.size == fields.size
      return mixed(working, fields - working.keys) if working.any?

      ours(fields)
    end

    private

    # Other enabled sources on the same adapter whose most recent run still
    # extracted this field above threshold.
    def siblings_still_extracting(field)
      CatalogSource
        .where(adapter_type: @source.adapter_type, enabled: true, is_deleted: [false, nil])
        .where.not(id: @source.id)
        .filter_map do |sibling|
          latest = ScrapeRun.where(catalog_source_id: sibling.id)
                            .where(started_at: SIBLING_WINDOW.ago..)
                            .order(started_at: :desc).first
          next if latest.nil?

          rate = latest.field_extraction_rates.to_h[field].to_f
          next if rate < sibling.extraction_threshold.to_f

          "#{sibling.name} #{(rate * 100).round}%"
        end
    rescue StandardError => e
      # A diagnosis is a courtesy on top of the alert. Losing it must not lose
      # the alert.
      Rails.logger.warn("[Catalog::DegradationDiagnosis] sibling lookup failed: #{e.message}")
      []
    end

    def upstream(working)
      evidence = working.map { |field, sources| "#{field} still extracts fine for #{sources.join(', ')}" }

      Result.new(
        verdict: :upstream,
        summary: 'Nothing to fix here — the pages themselves are missing this, not our extractor.',
        detail: "#{evidence.join('; ')}. The affected pages are the ones to chase with the " \
                'manufacturer; this will clear on its own when they republish.'
      )
    end

    def ours(fields)
      Result.new(
        verdict: :ours,
        summary: 'Worth looking at — every source on this adapter lost the same field.',
        detail: "No other #{@source.adapter_type} source extracted #{fields.join(', ')} in the " \
                'last two weeks either, which usually means the site changed shape rather than ' \
                'individual pages going blank.'
      )
    end

    def mixed(working, ours_fields)
      Result.new(
        verdict: :mixed,
        summary: 'Split: some of this is upstream, some may be ours.',
        detail: "Still fine elsewhere: #{working.keys.join(', ')}. " \
                "Missing everywhere on this adapter: #{ours_fields.join(', ')}."
      )
    end

    def inconclusive(reason)
      Result.new(verdict: :unknown, summary: nil, detail: reason)
    end
  end
end
