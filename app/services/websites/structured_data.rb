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
  # HomeGoodsStore rather than a bare LocalBusiness: it is a LocalBusiness
  # subtype, so it inherits everything, and it is the exact type Clayton uses on
  # its own retailer pages, which is the closest thing to a convention this
  # industry has.
  #
  # Every node is dropped when the data behind it is missing. A PostalAddress
  # with no street is worse than no PostalAddress, because it tells a search
  # engine we are describing a place and then fails to say where.
  class StructuredData
    CONTEXT = 'https://schema.org'

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
      [website_node, store_node, breadcrumb_node, product_node].compact
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
        'url' => base_url
      }
    end

    def store_node
      street = place.try(:address_line1).presence
      return nil if street.blank?

      node = {
        '@type' => 'HomeGoodsStore',
        '@id' => "#{base_url}/#store",
        'name' => site_name,
        'url' => base_url,
        'address' => {
          '@type' => 'PostalAddress',
          'streetAddress' => street,
          'addressLocality' => place.try(:city).presence,
          'addressRegion' => place.try(:state).presence,
          'addressCountry' => company.try(:country).presence || 'US'
        }.compact
      }

      node['telephone'] = place.try(:phone).presence || company.try(:phone).presence
      node['email'] = place.try(:email).presence || company.try(:email).presence
      node['image'] = brand['logo_url'].presence
      node['logo'] = brand['logo_url'].presence
      node.compact
    end

    # Home first, then the page. A one-item trail is just the site name and adds
    # nothing a search engine does not already have.
    def breadcrumb_node
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
        '@id' => home_url,
        'name' => name,
        'description' => @vehicle.description.to_s.truncate(300).presence,
        'sku' => @vehicle.vin.presence,
        'brand' => (@vehicle.make.presence && { '@type' => 'Brand', 'name' => @vehicle.make }),
        'image' => Array(vehicle_images).first(6).presence,
        'additionalProperty' => vehicle_properties.presence,
        'offers' => offer_node
      }.compact
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
