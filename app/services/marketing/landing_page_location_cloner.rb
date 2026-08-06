# frozen_string_literal: true

module Marketing
  # Fans one landing page out across several locations.
  #
  # The operation a dealer group actually pays for: one offer, twelve rooftops,
  # each with its own phone number, address, inventory, form and assigned rep.
  #
  # **Copy stays identical.** Only location-bound data varies. That is a product
  # decision (2026-08-06) and it has two consequences worth keeping:
  #
  #   1. The whole operation is deterministic — no AI call, no token spend, no
  #      credit limit to hit, and twelve locations complete as fast as one.
  #   2. Identical copy on N URLs is duplicate content, which is why landing
  #      pages default to noindex (WebsitePage#apply_landing_defaults).
  #
  # Partial success is reported, not rolled back. One location failing —
  # usually a name collision or a location with no users — should not cost the
  # eleven that worked.
  class LandingPageLocationCloner
    Result = Struct.new(:pages, :failures, keyword_init: true) do
      def cloned_count = pages.size
      def failed_count = failures.size
    end

    def initialize(page, user:, locations:, share_form: false)
      @page = page
      @user = user
      @locations = Array(locations)
      @share_form = share_form
    end

    def call
      pages = []
      failures = []

      @locations.each do |location|
        pages << clone_for(location)
      rescue StandardError => e
        Rails.logger.warn("[LandingPageLocationCloner] location=#{location.id}: #{e.message}")
        failures << { location_id: location.id, location_name: location.name, error: e.message }
      end

      Result.new(pages: pages, failures: failures)
    end

    private

    def clone_for(location)
      LandingPageDuplicator.new(
        @page,
        user: @user,
        # Named for the rooftop, not "(Copy)". Twelve pages all called
        # "(Copy) Spring Sale" are unusable in a list.
        title: "#{@page.title} — #{location.name}",
        location: location,
        campaign_id: @page.campaign_id,
        share_form: @share_form
      ).call
    end
  end
end
