# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module RenterInsight
  # The vacancies a landlord has published in Renter Insight, for their
  # DealerTide website.
  #
  # The landlord keeps listing units where they already manage them, and their
  # site shows what is open right now without anyone typing it twice. The data
  # is what Renter Insight already shows on its public listing page
  # (app.renterinsight.com/property-listings/<id>), read the same way that page
  # reads it: load the page for a session and CSRF token, then ask the search
  # endpoint for the whole company.
  #
  # That response carries far more than a listing (it returns the landlord's
  # company record). Nothing but the fields named in #listing and #property
  # leaves this class, so a change on the Renter Insight side cannot widen what
  # a public website shows.
  #
  # Failures return nil rather than raising. A vacancy list is part of a page,
  # and Renter Insight being slow must cost the visitor the list, not the site.
  class PublicListings
    BASE_URL = ENV.fetch('RENTER_INSIGHT_APP_URL', 'https://app.renterinsight.com')
    TIMEOUT = 8
    CACHE_TTL = 10.minutes
    # Listing ids are numeric hash ids in Renter Insight URLs.
    LISTING_ID = /\A[0-9]{4,20}\z/
    MAX_DESCRIPTION = 4000
    META_SPECS = /Beds:\s*(?<beds>[^|]+)\|\s*Baths:\s*(?<baths>[\d.]+)\s*\|\s*SQFT:\s*(?<sqft>[\d,]+)/i

    class << self
      def valid_id?(listing_id)
        listing_id.to_s.match?(LISTING_ID)
      end

      # @return [Hash, nil] { listings: [...], property: {...} } or nil when
      #   the listing id is invalid or Renter Insight could not be read
      def fetch(listing_id)
        id = listing_id.to_s
        return nil unless valid_id?(id)

        Rails.cache.fetch("ri_public_listings:v1:#{id}", expires_in: CACHE_TTL, skip_nil: true) do
          new(id).call
        end
      end
    end

    def initialize(listing_id)
      @listing_id = listing_id
    end

    def call
      raw = request_search
      return nil unless raw.is_a?(Hash) && raw['unit_listings'].is_a?(Array)

      properties = Array(raw['properties'])
      {
        listings: raw['unit_listings'].filter_map { |u| listing(u) if active?(u) }.sort_by { |l| [l[:available_on] || '', l[:rent] || 0] },
        property: property(properties.first)
      }
    rescue StandardError => e
      Rails.logger.warn("[RenterInsight::PublicListings] #{@listing_id}: #{e.class}: #{e.message}")
      nil
    end

    private

    def active?(unit)
      unit['status'].to_s == 'active'
    end

    def listing(unit)
      specs = parse_specs(unit['metadata_description'])
      beds = specs[:beds]
      {
        id: unit['hash_id'].to_s,
        title: [beds_label(beds), unit_label(street_and_unit(unit))].compact.join(', ').presence || street_and_unit(unit),
        unit: unit_label(street_and_unit(unit)),
        beds: beds,
        beds_label: beds_label(beds),
        baths: specs[:baths],
        sqft: specs[:sqft],
        rent: number(unit['rent']),
        deposit: number(unit['security_deposit']),
        lease_term_months: unit['lease_term'].to_i.positive? ? unit['lease_term'].to_i : nil,
        available_on: date(unit['available_on']),
        available_now: available_now?(unit['available_on']),
        description: unit['description'].to_s.strip.first(MAX_DESCRIPTION),
        photo_url: https_url(unit['photo_url']),
        listing_url: "#{BASE_URL}/property-listings/#{@listing_id}"
      }
    end

    def street_and_unit(unit)
      unit['street_and_unit'].presence || unit['name'].to_s
    end

    def property(prop)
      return nil unless prop.is_a?(Hash)

      {
        name: prop['name'].presence,
        street: prop['street'].presence,
        city: prop['city'].presence,
        state: prop['state'].presence,
        zip: prop['zip'].presence
      }.compact.presence
    end

    # Renter Insight puts beds, baths and size only in the listing's meta
    # description ("Beds: Studio | Baths: 1.0 | SQFT: 450 | ..."); the listing
    # record itself has none of them.
    def parse_specs(text)
      m = META_SPECS.match(text.to_s)
      return {} unless m

      raw_beds = m[:beds].strip
      beds = raw_beds.match?(/studio/i) ? 0 : raw_beds[/\d+/]&.to_i
      { beds: beds, baths: number(m[:baths]), sqft: m[:sqft].delete(',').to_i.nonzero? }
    end

    def beds_label(beds)
      return nil if beds.nil?
      return 'Studio' if beds.zero?

      "#{beds} Bedroom"
    end

    # "2124 California Ave SW, Unit #203" -> "Unit 203"
    def unit_label(text)
      text.to_s[/unit\s*#?\s*([\w-]+)/i, 1]&.then { |n| "Unit #{n}" }
    end

    def number(value)
      return nil if value.blank?

      f = Float(value, exception: false)
      return nil if f.nil? || f.negative?

      (f % 1).zero? ? f.to_i : f
    end

    def date(value)
      Date.iso8601(value.to_s).iso8601
    rescue ArgumentError
      nil
    end

    def available_now?(value)
      d = Date.iso8601(value.to_s)
      d <= Time.zone.today
    rescue ArgumentError
      true
    end

    def https_url(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) ? uri.to_s : nil
    rescue URI::InvalidURIError
      nil
    end

    def request_search
      page_uri = URI("#{BASE_URL}/property-listings/#{@listing_id}")
      page = http(page_uri).request(Net::HTTP::Get.new(page_uri, headers))
      return nil unless page.is_a?(Net::HTTPSuccess)

      token = page.body.to_s[/<meta name="csrf-token" content="([^"]+)"/, 1]
      cookies = Array(page.get_fields('set-cookie')).map { |c| c.split(';').first }.join('; ')
      return nil if token.blank?

      search_uri = URI("#{BASE_URL}/api/internal/property_listings/search")
      req = Net::HTTP::Post.new(search_uri, headers.merge(
        'Content-Type' => 'application/json', 'X-CSRF-Token' => token, 'Cookie' => cookies
      ))
      req.body = { property_listing_id: @listing_id, entire_company: true }.to_json
      res = http(search_uri).request(req)
      return nil unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    end

    def headers
      { 'Accept' => 'application/json, text/html', 'User-Agent' => 'DealerTide-Sites/1.0' }
    end

    def http(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |h|
        h.use_ssl = uri.scheme == 'https'
        h.open_timeout = TIMEOUT
        h.read_timeout = TIMEOUT
      end
    end
  end
end
