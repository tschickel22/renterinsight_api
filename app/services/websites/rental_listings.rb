# frozen_string_literal: true

module Websites
  # The vacancies a website shows through its rental listings blocks.
  #
  # The block holds the source and the listing id; the listings themselves live
  # with the landlord in Renter Insight. Markup, the crawlable body and llms.txt
  # all read them through here, so none of them can describe a unit the visible
  # block would not show.
  module RentalListings
    BLOCK_TYPE = 'rentalListings'

    module_function

    # @return [Array<Hash>] block content hashes of rental listings blocks on a page
    def blocks_on(page)
      return [] if page.nil?

      Array(page.try(:blocks)).filter_map do |block|
        next unless block.is_a?(Hash) && block['type'].to_s == BLOCK_TYPE

        content = block['content'].is_a?(Hash) ? block['content'] : {}
        content if RenterInsight::PublicListings.valid_id?(content['listingId'])
      end
    end

    # @return [Array<String>] distinct listing ids shown anywhere on the site
    def listing_ids_for(website)
      website.website_pages.flat_map { |p| blocks_on(p).map { |c| c['listingId'].to_s } }.uniq
    rescue StandardError
      []
    end

    # @return [Array<Hash>] the open listings for these ids, in display order
    def listings_for(ids)
      Array(ids).uniq.flat_map do |id|
        Array(RenterInsight::PublicListings.fetch(id)&.dig(:listings))
      end
    end

    def for_page(page)
      listings_for(blocks_on(page).map { |c| c['listingId'].to_s })
    end

    def for_website(website)
      listings_for(listing_ids_for(website))
    end

    # "$1,400/month", "Studio", "Available now" style facts, shared wording.
    def rent_label(listing)
      rent = listing[:rent]
      return nil unless rent.to_f.positive?

      "$#{ActiveSupport::NumberHelper.number_to_delimited(rent.to_i)}/month"
    end

    def availability_label(listing)
      return 'Available now' if listing[:available_now]
      return nil if listing[:available_on].blank?

      "Available #{Date.iso8601(listing[:available_on]).strftime('%B %-d, %Y')}"
    rescue ArgumentError
      nil
    end
  end
end
