# frozen_string_literal: true

module SiteProfiles
  # Home photography from a lot we already hold, for use when a scan's imagery
  # is unusable.
  #
  # A dealer site scan returns whatever is on the page, and on a real dealer
  # home page that is frequently not a home: an American flag, a "4th of July
  # Blowout" banner, a financing-partner badge, a stock photo of a handshake.
  # Those are the images that ended up behind headlines on every generated page.
  #
  # We already store photographs of actual manufactured homes, on actual lots,
  # with the dealer's own stock. Preferring those over a scraped banner is both
  # more accurate and more flattering, and it costs nothing.
  #
  # Ordered so the strongest exteriors lead: a listing's primary image is the
  # one the dealer chose to represent it, so it outranks the rest of its gallery.
  class InventoryImagery
    MAX_IMAGES = 24
    MAX_VEHICLES = 40

    # Interiors and detail shots make poor heroes at hero crop, and floor plan
    # renders are line art. Exclude by filename where we can tell.
    NON_EXTERIOR = /floor[-_]?plan|interior|kitchen|bath|bedroom|closet|laundry|detail|spec/i

    class << self
      # Resolve the lot the way every other demo surface does, so the imagery
      # matches the inventory the block will actually render.
      def for_profile(profile)
        config = DemoInventoryResolver.config_for_profile(profile)
        return [] if config.blank?

        for_company(Company.find_by(id: config['company_id']))
      end

      # @return [Array<String>] absolute image URLs, exteriors first
      def for_company(company)
        return [] if company.nil?

        vehicles = available_vehicles(company)
        return [] if vehicles.empty?

        primaries = vehicles.filter_map { |v| first_url(v.images) }
        rest = vehicles.flat_map { |v| all_urls(v.images).drop(1) }

        exteriors, others = (primaries + rest).compact.uniq.partition { |u| !NON_EXTERIOR.match?(u) }
        (exteriors + others).first(MAX_IMAGES)
      rescue StandardError => e
        Rails.logger.warn("[SiteProfiles::InventoryImagery] lookup failed for #{company&.id}: #{e.message}")
        []
      end

      private

      # Newest first: a lot's recent arrivals are the ones with current
      # photography, and older rows are likelier to carry a placeholder.
      def available_vehicles(company)
        company.vehicles
               .where(status: %w[available available_to_order])
               .where(is_deleted: [false, nil])
               .order(created_at: :desc)
               .limit(MAX_VEHICLES)
               .to_a
      end

      def all_urls(images)
        Array(images).filter_map do |img|
          url = img.is_a?(Hash) ? (img['url'] || img[:url]) : img
          url = url.to_s.strip
          url.presence if url.start_with?('http')
        end
      end

      def first_url(images)
        all_urls(images).first
      end
    end
  end
end
