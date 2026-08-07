# frozen_string_literal: true

module Marketing
  # Attributes a visitor's whole session history to the person they turned out
  # to be.
  #
  # The differentiator in landing page tracking. A visitor browses anonymously —
  # three pages, two videos, a scroll to the bottom — and only becomes a name at
  # the moment they submit a form. Attributing just that final page throws away
  # everything that actually explains the conversion.
  #
  # IntakeSubmission already runs IdentityResolver and either absorbs into an
  # existing lead or attaches to an existing contact. This runs after that, on
  # whatever entity it resolved to, and back-stamps every earlier anonymous
  # visit carrying the same visitor_token.
  class IdentifyVisitor
    # How far back to claim anonymous visits.
    #
    # A shared or public browser makes very old visits a bad guess, and the
    # window is a PlatformSetting so it can be tuned without a deploy —
    # matching the attribution window the campaign plan already recommends.
    DEFAULT_WINDOW_DAYS = 60

    Result = Struct.new(:visits_identified, :entity, keyword_init: true)

    def initialize(company:, visitor_token:, entity:, window_days: nil)
      @company = company
      @visitor_token = visitor_token.to_s
      @entity = entity
      @window_days = window_days
    end

    def call
      return Result.new(visits_identified: 0, entity: @entity) if skip?

      visits = claimable_visits
      count = 0

      visits.find_each do |visit|
        count += 1 if visit.identify!(@entity)
      end

      Result.new(visits_identified: count, entity: @entity)
    rescue StandardError => e
      # Identification is an enrichment. It must never break the form
      # submission that triggered it — a lead that was captured but not
      # attributed is a reporting gap; a lead that was lost is a lost sale.
      Rails.logger.warn("[IdentifyVisitor] #{e.class}: #{e.message}")
      Result.new(visits_identified: 0, entity: @entity)
    end

    private

    def skip?
      @visitor_token.blank? || @entity.nil? || @company.nil?
    end

    # Only unidentified visits. A visit already resolved to someone else stays
    # with them — two people sharing a browser is rarer than a re-submitted
    # form, and reassigning the first person's session is worse than missing it.
    def claimable_visits
      PageVisit
        .where(company_id: @company.id, visitor_token: @visitor_token)
        .where(identified_entity_id: nil)
        .where(first_seen_at: window_start..)
    end

    def window_start
      days = @window_days || configured_window_days
      days.days.ago
    end

    def configured_window_days
      value = Setting.get('Platform', 0, 'marketing')&.dig('attribution_window_days')
      value.presence&.to_i || DEFAULT_WINDOW_DAYS
    rescue StandardError
      DEFAULT_WINDOW_DAYS
    end
  end
end
