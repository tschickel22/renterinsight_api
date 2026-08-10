# frozen_string_literal: true

module Websites
  # The schema.org graph emitted into a tenant page's head.
  #
  # This is what lets a search engine understand that a page is a dealership at
  # an address selling a home at a price, rather than a document containing those
  # words. It is also what AI assistants read when deciding what to quote, which
  # is the ground the market is currently competing on.
  #
  # Written against a measured competitor rather than a checklist. A Trove-built
  # site emits WebSite and Product only, and our own SeoAudit flags it for the
  # two things missing here: no LocalBusiness, which is what map and local
  # results are built from, and no BreadcrumbList, which is what replaces a raw
  # URL in a result with a readable trail. Emitting all four means a dealer on
  # our platform is marked up better than the best thing in the category, not
  # merely level with it.
  #
  # The business type follows the dealer's industry rather than being fixed.
  # This used to emit HomeGoodsStore for everyone, on the reasoning that Clayton
  # uses it and it is a LocalBusiness subtype. Structurally that is true, but
  # schema.org defines HomeGoodsStore as a housewares shop, so we were telling
  # Google that a manufactured housing dealer sells cookware. An RV lot gets
  # AutoDealer, which is exact; manufactured housing has no precise type, so it
  # gets plain LocalBusiness rather than a wrong specific one.
  #
  # Every node is dropped when the data behind it is missing. A PostalAddress
  # with no street is worse than no PostalAddress, because it tells a search
  # engine we are describing a place and then fails to say where.
  class StructuredData
    CONTEXT = 'https://schema.org'

    # schema.org has no manufactured housing type, and a wrong specific type is
    # worse than a correct general one.
    BUSINESS_TYPE_BY_INDUSTRY = {
      'rv' => 'AutoDealer',
      'property_management' => 'RealEstateAgent',
      'storage' => 'SelfStorage'
    }.freeze
    DEFAULT_BUSINESS_TYPE = 'LocalBusiness'

    # Day order matters: Google reads openingHoursSpecification as written.
    DAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze

    # Enough homes to establish the lot without turning one page into a feed.
    MAX_LISTED = 12

    def initialize(website:, page:, canonical_host:, vehicle: nil)
      @website = website
      @page = page
      @canonical_host = canonical_host
      @vehicle = vehicle
    end

    # @return [String, nil] a JSON-LD script tag, or nil when there is nothing
    #   worth saying
    def to_tag
      nodes = graph
      return nil if nodes.empty?

      payload = { '@context' => CONTEXT, '@graph' => nodes }
      # JSON inside a <script> needs the closing sequence broken, or a description
      # containing "</script>" ends the block early and the rest lands in the body.
      json = payload.to_json.gsub('</', '<\/')

      %(<script type="application/ld+json">#{json}</script>)
    end

    def graph
      [website_node, store_node, breadcrumb_node, product_node, item_list_node].compact
    end

    private

    def base_url
      @base_url ||= "https://#{@canonical_host}"
    end

    def brand
      @brand ||= @website.brand.to_h
    end

    def company
      @company ||= @website.company
    end

    # The site's own location when it has a street, since a multi-lot dealer's
    # site should name the lot it belongs to rather than head office.
    #
    # Falls back on the street specifically, not on the location being present:
    # locations are created with a name and nothing else, so preferring any
    # location at all silenced the whole node for a company whose address was
    # sitting right there.
    def place
      @place ||= if @website.location&.address_line1.presence
                   @website.location
                 else
                   company
                 end
    end

    def site_name
      brand['company_name'].presence || company&.name.presence || @website.name
    end

    def website_node
      {
        '@type' => 'WebSite',
        '@id' => "#{base_url}/#site",
        'name' => site_name,
        'url' => base_url,
        # Ties the site and the business into one entity. Without it Google sees
        # a website and a shop that merely happen to share a domain, and the
        # reviews, hours and address attach to neither.
        'publisher' => (store_node ? { '@id' => store_id } : nil)
      }.compact
    end

    def store_id
      "#{base_url}/#store"
    end

    def business_type
      BUSINESS_TYPE_BY_INDUSTRY.fetch(company.try(:industry).to_s, DEFAULT_BUSINESS_TYPE)
    end

    def store_node
      @store_node ||= build_store_node
    end

    def build_store_node
      street = place.try(:address_line1).presence
      return nil if street.blank?

      node = {
        '@type' => business_type,
        '@id' => store_id,
        'name' => site_name,
        'url' => base_url,
        'address' => {
          '@type' => 'PostalAddress',
          'streetAddress' => street,
          'addressLocality' => place.try(:city).presence,
          'addressRegion' => place.try(:state).presence,
          # Was absent entirely, which is what a local search matches a
          # dealership against. Name, address and phone have to agree with the
          # Google Business Profile, and an address with no postal code cannot.
          'postalCode' => place.try(:zip_code).presence,
          'addressCountry' => company.try(:country).presence || 'US'
        }.compact
      }

      node['telephone'] = place.try(:phone).presence || company.try(:phone).presence
      node['email'] = place.try(:email).presence || company.try(:email).presence
      # A logo when the dealer uploaded one, otherwise a home off their own lot.
      # Google flags a local business with no image, and every dealer has stock
      # even when they never got round to a logo.
      node['image'] = brand['logo_url'].presence || first_inventory_image
      node['logo'] = brand['logo_url'].presence
      node['priceRange'] = price_range
      node['openingHoursSpecification'] = opening_hours.presence
      node['areaServed'] = area_served
      node.compact
    end

    # Read off the lot rather than guessed. Google asks for priceRange on a
    # local business, and "$$" tells a buyer nothing when we know the actual
    # spread of what this dealer sells.
    def price_range
      prices = servable_homes.filter_map { |v| v.sale_price.to_f if v.sale_price.to_f.positive? }
      return nil if prices.empty?

      low = prices.min.round
      high = prices.max.round
      return "$#{number_with_delimiter(low)}" if low == high

      "$#{number_with_delimiter(low)} to $#{number_with_delimiter(high)}"
    end

    # From the dealer's own stored hours. Emitted only for days they actually
    # open: a day marked closed is left out rather than published as 00:00 to
    # 00:00, which reads to a search engine as open around the clock.
    def opening_hours
      hours = place.try(:business_hours)
      return [] unless hours.is_a?(Hash)

      DAYS.filter_map do |day|
        spec = hours[day] || hours[day.to_sym]
        next unless spec.is_a?(Hash)

        closed = ActiveModel::Type::Boolean.new.cast(spec['closed'] || spec[:closed])
        next if closed

        opens = (spec['open'] || spec[:open]).to_s.presence
        closes = (spec['close'] || spec[:close]).to_s.presence
        next if opens.blank? || closes.blank?

        {
          '@type' => 'OpeningHoursSpecification',
          'dayOfWeek' => "https://schema.org/#{day.capitalize}",
          'opens' => opens,
          'closes' => closes
        }
      end
    end

    # Where they sell, stated plainly. Only what we can stand behind: the town
    # and state the lot is in, not an invented radius.
    def area_served
      city = place.try(:city).presence
      state = place.try(:state).presence
      return nil if city.blank? && state.blank?

      { '@type' => 'Place', 'name' => [city, state].compact.join(', ') }
    end

    def first_inventory_image
      servable_homes.each do |vehicle|
        url = vehicle.public_image_urls.first
        return url if url.present?
      end
      nil
    rescue StandardError
      nil
    end

    # The same scope the sitemap and the public grid use, so markup can never
    # advertise a home the site would refuse to show.
    def servable_homes
      @servable_homes ||= begin
        company.nil? ? [] : company.vehicles
                                   .where(is_deleted: [false, nil], status: HomeUrl::SERVABLE_STATUSES)
                                   .order(updated_at: :desc)
                                   .limit(MAX_LISTED)
                                   .to_a
      end
    rescue StandardError
      @servable_homes = []
    end

    def number_with_delimiter(value)
      ActiveSupport::NumberHelper.number_to_delimited(value.to_i)
    end

    # Home first, then the page. A one-item trail is just the site name and adds
    # nothing a search engine does not already have.
    def breadcrumb_node
      return home_breadcrumb_node if @vehicle.present?

      path = @page&.path.to_s
      return nil if path.blank? || path == '/' || @page.nil?

      title = @page.title.presence || @page.seo_title.presence
      return nil if title.blank?

      {
        '@type' => 'BreadcrumbList',
        '@id' => "#{base_url}#{normalized_path(path)}#breadcrumbs",
        'itemListElement' => [
          { '@type' => 'ListItem', 'position' => 1, 'name' => 'Home', 'item' => base_url },
          { '@type' => 'ListItem', 'position' => 2, 'name' => title,
            'item' => "#{base_url}#{normalized_path(path)}" }
        ]
      }
    end

    # The node the competitor does have, and the one that carries price into a
    # search result.
    #
    # additionalProperty for beds, baths and square feet is the part their markup
    # lacks: their description says "3 bedrooms" in prose, which no engine can
    # filter on. Structured, it can.
    def product_node
      return nil if @vehicle.nil?

      name = vehicle_name
      return nil if name.blank?

      {
        '@type' => 'Product',
        # A home is a dwelling as well as a thing for sale. additionalProperty
        # carried the beds and baths as untyped name/value pairs, which reads as
        # a spec table; these are the properties an assistant answering "3 bed
        # under 90k" can actually filter on.
        'additionalType' => 'https://schema.org/SingleFamilyResidence',
        '@id' => home_url,
        'name' => name,
        'description' => @vehicle.description.to_s.truncate(300).presence,
        'sku' => @vehicle.vin.presence,
        'brand' => (@vehicle.make.presence && { '@type' => 'Brand', 'name' => @vehicle.make }),
        'image' => Array(vehicle_images).first(6).presence,
        'numberOfBedrooms' => positive_number(@vehicle.bedrooms),
        'numberOfBathroomsTotal' => positive_number(@vehicle.bathrooms),
        'floorSize' => floor_size,
        'additionalProperty' => vehicle_properties.presence,
        'offers' => offer_node,
        'seller' => (store_node ? { '@id' => store_id } : nil)
      }.compact
    end

    def positive_number(value)
      number = value.to_f
      return nil unless number.positive?

      (number % 1).zero? ? number.to_i : number
    end

    def floor_size
      size = @vehicle.square_feet.to_i
      return nil unless size.positive?

      { '@type' => 'QuantitativeValue', 'value' => size, 'unitCode' => 'FTK' }
    end

    # Home > Homes > this home. A listing reached from search otherwise shows a
    # raw URL where competitors show a trail.
    def home_breadcrumb_node
      name = vehicle_name
      return nil if name.blank?

      {
        '@type' => 'BreadcrumbList',
        '@id' => "#{home_url}#breadcrumbs",
        'itemListElement' => [
          { '@type' => 'ListItem', 'position' => 1, 'name' => 'Home', 'item' => base_url },
          { '@type' => 'ListItem', 'position' => 2, 'name' => 'Homes',
            'item' => "#{base_url}#{HomeUrl::PREFIX}" },
          { '@type' => 'ListItem', 'position' => 3, 'name' => name, 'item' => home_url }
        ]
      }
    end

    # What the lot actually holds, as a list rather than a grid an engine has to
    # execute. This is the node that lets an assistant answer "what do they have"
    # without crawling every listing, and nothing was emitting it.
    def item_list_node
      return nil if @vehicle.present?

      homes = servable_homes
      return nil if homes.empty?

      items = homes.each_with_index.filter_map do |vehicle, index|
        url = HomeUrl.url_for(vehicle, @canonical_host)
        next if url.blank?

        label = [vehicle.year, vehicle.make, vehicle.model].map(&:presence).compact.join(' ').presence
        next if label.blank?

        { '@type' => 'ListItem', 'position' => index + 1, 'name' => label, 'url' => url }
      end
      return nil if items.empty?

      {
        '@type' => 'ItemList',
        '@id' => "#{base_url}#homes",
        'name' => "Homes for sale at #{site_name}",
        'numberOfItems' => items.size,
        'itemListElement' => items
      }
    end

    def vehicle_name
      [@vehicle.year, @vehicle.make, @vehicle.model].map(&:presence).compact.join(' ').presence
    end

    def vehicle_images
      @vehicle.public_image_urls
    rescue StandardError
      []
    end

    # A home's own URL, so the entity is identified by the page that describes
    # it. Anchoring it to the site root instead would give every home on the site
    # a different fragment of the same identity.
    def home_url
      HomeUrl.url_for(@vehicle, @canonical_host) || base_url
    end

    def vehicle_properties
      {
        'Bedrooms' => @vehicle.bedrooms,
        'Bathrooms' => @vehicle.bathrooms,
        'Square feet' => @vehicle.square_feet
      }.filter_map do |label, value|
        next if value.blank?

        { '@type' => 'PropertyValue', 'name' => label, 'value' => value.to_s }
      end
    end

    def offer_node
      price = @vehicle.sale_price
      return nil if price.blank? || price.to_f <= 0

      {
        '@type' => 'Offer',
        'price' => price.to_f.round,
        'priceCurrency' => 'USD',
        'availability' => availability,
        'itemCondition' => @vehicle.condition.to_s.casecmp?('used') ?
          'https://schema.org/UsedCondition' : 'https://schema.org/NewCondition',
        'url' => home_url
      }
    end

    # Only the statuses the public inventory endpoint will actually serve count
    # as in stock, so the markup cannot advertise a home the site will not show.
    def availability
      case @vehicle.status.to_s
      when 'available', 'available_to_order' then 'https://schema.org/InStock'
      else 'https://schema.org/OutOfStock'
      end
    end

    def normalized_path(path)
      path.start_with?('/') ? path : "/#{path}"
    end
  end
end
