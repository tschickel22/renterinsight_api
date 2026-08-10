# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::StructuredData do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', phone: '555-0100', email: 'sales@summit.test',
                    address_line1: '100 Lot Road', city: 'Denver', state: 'CO')
  end
  let(:location) { company.locations.create!(name: 'Denver Showroom') }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit Park',
                    slug: "s-#{SecureRandom.hex(4)}", brand: { 'logo_url' => 'https://cdn.test/logo.png' })
  end
  let(:page) { website.website_pages.create!(title: 'Inventory', path: '/inventory', order: 1) }

  def graph(page: nil, vehicle: nil, site: nil)
    described_class.new(website: site || website, page: page,
                        canonical_host: 'summitpark.mydealertide.com', vehicle: vehicle).graph
  end

  def node(nodes, type)
    nodes.find { |n| n['@type'] == type }
  end

  describe 'the site node' do
    it 'always names the site and its canonical URL' do
      site = node(graph, 'WebSite')

      expect(site['name']).to eq('Summit Park Homes')
      expect(site['url']).to eq('https://summitpark.mydealertide.com')
    end
  end

  # The gap our own audit finds on every competitor site measured so far.
  describe 'the local business node' do
    it 'describes the dealership as a place with an address' do
      store = node(graph, 'LocalBusiness')

      expect(store['address']).to include(
        '@type' => 'PostalAddress',
        'streetAddress' => '100 Lot Road',
        'addressLocality' => 'Denver',
        'addressRegion' => 'CO'
      )
      expect(store['telephone']).to eq('555-0100')
      expect(store['logo']).to eq('https://cdn.test/logo.png')
    end

    # schema.org defines HomeGoodsStore as a housewares shop, which is what this
    # used to emit for every dealer on the platform.
    it 'takes its type from the industry, and never guesses a wrong specific one' do
      expect(node(graph, 'LocalBusiness')).to be_present

      company.update!(industry: 'rv')
      website.reload
      expect(node(graph, 'AutoDealer')).to be_present
    end

    # What a local search matches a dealership against. Absent entirely before,
    # so name, address and phone could not agree with the Business Profile.
    it 'carries the postal code' do
      company.update!(zip_code: '80231')

      expect(node(graph, 'LocalBusiness')['address']['postalCode']).to eq('80231')
    end

    it 'publishes only the days the dealer is actually open' do
      location.update!(address_line1: '9 Showroom Way', business_hours: {
                         'monday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
                         'sunday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => true }
                       })
      hours = node(graph, 'LocalBusiness')['openingHoursSpecification']

      expect(hours.map { |h| h['dayOfWeek'] }).to eq(['https://schema.org/Monday'])
      expect(hours.first).to include('opens' => '09:00', 'closes' => '17:00')
    end

    it 'states a price range read off the lot rather than a guess' do
      company.vehicles.create!(vin: SecureRandom.hex(8), status: 'available', sale_price: 89_900,
                               year: 2026, make: 'Skyline', model: 'A')
      company.vehicles.create!(vin: SecureRandom.hex(8), status: 'available', sale_price: 154_000,
                               year: 2026, make: 'Skyline', model: 'B')

      expect(node(graph, 'LocalBusiness')['priceRange']).to eq('$89,900 to $154,000')
    end

    it 'says nothing about price when no home on the lot has one' do
      company.vehicles.create!(vin: SecureRandom.hex(8), status: 'available', year: 2026,
                               make: 'Skyline', model: 'A')

      expect(node(graph, 'LocalBusiness')).not_to have_key('priceRange')
    end

    # Google flags a local business with no image, and every dealer has stock
    # even when they never got round to a logo.
    it 'falls back to a home off the lot when the dealer has no logo' do
      plain = Website.create!(company_id: company.id, location_id: location.id, name: 'Plain',
                              slug: "s-#{SecureRandom.hex(4)}")
      company.vehicles.create!(vin: SecureRandom.hex(8), status: 'available', year: 2026,
                               make: 'Skyline', model: 'A',
                               images: [{ 'url' => 'https://cdn.test/home.jpg' }])

      expect(node(graph(site: plain), 'LocalBusiness')['image']).to eq('https://cdn.test/home.jpg')
    end

    # Otherwise Google sees a website and a shop that happen to share a domain.
    it 'is named as the site publisher, so the two are one entity' do
      nodes = graph

      expect(node(nodes, 'WebSite')['publisher']).to eq('@id' => node(nodes, 'LocalBusiness')['@id'])
    end

    # A PostalAddress with no street tells a search engine we are describing a
    # place and then fails to say where, which is worse than staying silent.
    it 'is omitted entirely when there is no street address' do
      bare = Company.create!(name: 'No Address Co')
      site = Website.create!(company_id: bare.id, location_id: bare.locations.create!(name: 'L').id,
                             name: 'Bare', slug: "s-#{SecureRandom.hex(4)}")

      expect(node(graph(site: site), 'LocalBusiness')).to be_nil
    end

    it 'prefers the site location over head office when the location has one' do
      location.update!(address_line1: '9 Showroom Way', city: 'Boulder', state: 'CO')

      expect(node(graph, 'LocalBusiness')['address']['streetAddress']).to eq('9 Showroom Way')
    end
  end

  describe 'breadcrumbs' do
    it 'gives a two-step trail from home to the page' do
      trail = node(graph(page: page), 'BreadcrumbList')['itemListElement']

      expect(trail.map { |i| i['name'] }).to eq(%w[Home Inventory])
      expect(trail.last['item']).to eq('https://summitpark.mydealertide.com/inventory')
    end

    # A one-item trail is just the site name, which adds nothing.
    it 'says nothing on the home page' do
      home = website.website_pages.create!(title: 'Home', path: '/', order: 0)

      expect(node(graph(page: home), 'BreadcrumbList')).to be_nil
    end
  end

  describe 'the product node' do
    let(:vehicle) do
      company.vehicles.create!(year: 2026, make: 'Champion', model: 'Shoal Creek',
                               sale_price: 236_900, status: 'available', condition: 'new',
                               bedrooms: 3, bathrooms: 2, square_feet: 1493, vin: 'ABC123')
    end

    it 'carries the price a search result would show' do
      offer = node(graph(vehicle: vehicle), 'Product')['offers']

      expect(offer).to include('price' => 236_900, 'priceCurrency' => 'USD',
                               'availability' => 'https://schema.org/InStock',
                               'itemCondition' => 'https://schema.org/NewCondition')
    end

    # The part the competitor's markup lacks: their prose says "3 bedrooms",
    # which nothing can filter on.
    it 'structures beds, baths and size instead of leaving them in prose' do
      props = node(graph(vehicle: vehicle), 'Product')['additionalProperty']

      expect(props).to include(
        { '@type' => 'PropertyValue', 'name' => 'Bedrooms', 'value' => '3' },
        { '@type' => 'PropertyValue', 'name' => 'Square feet', 'value' => '1493' }
      )
    end

    # The column stores [{"url" => ...}], so reading it raw yields hashes and a
    # home's own photograph silently vanished from its markup.
    it 'uses the home\'s own photographs' do
      vehicle.update!(images: [{ 'url' => 'https://cdn.test/front.jpg' }])

      expect(node(graph(vehicle: vehicle), 'Product')['image']).to eq(['https://cdn.test/front.jpg'])
    end

    it 'identifies the home by its own URL rather than the site root' do
      product = node(graph(vehicle: vehicle), 'Product')

      expect(product['@id']).to end_with("/homes/2026-champion-shoal-creek-#{vehicle.id}")
      expect(product['offers']['url']).to eq(product['@id'])
    end

    it 'names the home and its manufacturer' do
      product = node(graph(vehicle: vehicle), 'Product')

      expect(product['name']).to eq('2026 Champion Shoal Creek')
      expect(product['brand']).to eq({ '@type' => 'Brand', 'name' => 'Champion' })
      expect(product['sku']).to eq('ABC123')
    end

    # Markup must not advertise a home the public endpoint refuses to serve.
    it 'marks a home the site will not show as out of stock' do
      vehicle.update!(status: 'sold')

      expect(node(graph(vehicle: vehicle), 'Product')['offers']['availability'])
        .to eq('https://schema.org/OutOfStock')
    end

    it 'omits the offer rather than quoting a price of zero' do
      vehicle.update!(sale_price: 0)

      expect(node(graph(vehicle: vehicle), 'Product')['offers']).to be_nil
    end

    it 'says nothing when no home was requested' do
      expect(node(graph, 'Product')).to be_nil
    end
  end

  describe 'the emitted tag' do
    subject(:tag) { described_class.new(website: website, page: page, canonical_host: 'h.test').to_tag }

    it 'is a parseable ld+json script' do
      json = tag[%r{<script type="application/ld\+json">(.*)</script>}m, 1]

      expect(JSON.parse(json)['@context']).to eq('https://schema.org')
      expect(JSON.parse(json)['@graph']).to be_an(Array)
    end

    # Otherwise a description containing the closing sequence ends the block
    # early and the rest of the JSON renders as body text.
    it 'cannot be broken out of by content containing a closing tag' do
      website.update!(name: 'Bad </script><img> Name', brand: {})
      company.update!(name: 'Bad </script> Co')

      expect(described_class.new(website: website, page: page, canonical_host: 'h.test').to_tag)
        .not_to include('</script><img>')
    end
  end

  # Measured on the live site with Google's Rich Results Test: a listing emitted
  # a Product with no offer and its beds and baths as untyped name/value pairs,
  # and no trail at all.
  describe 'a home listing' do
    let(:home) do
      company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                               model: 'Prairie Dune 8710', status: 'available',
                               bedrooms: 3, bathrooms: 2, square_feet: 1023, sale_price: 89_900,
                               images: [{ 'url' => 'https://cdn.test/front.jpg' }])
    end

    subject(:nodes) { graph(vehicle: home) }

    it 'describes the dwelling in properties an assistant can filter on' do
      product = node(nodes, 'Product')

      expect(product['additionalType']).to eq('https://schema.org/SingleFamilyResidence')
      expect(product['numberOfBedrooms']).to eq(3)
      expect(product['numberOfBathroomsTotal']).to eq(2)
      expect(product['floorSize']).to eq('@type' => 'QuantitativeValue', 'value' => 1023,
                                         'unitCode' => 'FTK')
    end

    it 'carries the price into the result' do
      expect(node(nodes, 'Product')['offers']).to include(
        'price' => 89_900, 'priceCurrency' => 'USD', 'availability' => 'https://schema.org/InStock'
      )
    end

    it 'names the dealership as the seller, rather than leaving the home unattached' do
      expect(node(nodes, 'Product')['seller']).to eq('@id' => node(nodes, 'LocalBusiness')['@id'])
    end

    # A listing reached from search showed a raw URL where competitors show a
    # trail, because the breadcrumb builder only ever looked at a page record.
    it 'gets a trail of its own' do
      trail = node(nodes, 'BreadcrumbList')['itemListElement']

      expect(trail.map { |i| i['name'] }).to eq(['Home', 'Homes', '2026 Skyline Homes Prairie Dune 8710'])
    end

    it 'does not list the whole lot on a single home page' do
      expect(node(nodes, 'ItemList')).to be_nil
    end
  end

  # What lets an assistant answer "what do they have" without crawling every
  # listing. Nothing was emitting it.
  describe 'the lot as a list' do
    before do
      company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline', model: 'A',
                               status: 'available')
      company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline', model: 'Sold',
                               status: 'sold')
    end

    it 'lists the homes with their own addresses' do
      list = node(graph, 'ItemList')

      expect(list['numberOfItems']).to eq(1)
      expect(list['itemListElement'].first).to include('position' => 1, 'name' => '2026 Skyline A')
      expect(list['itemListElement'].first['url']).to include('/homes/')
    end

    it 'never lists a home the site would refuse to serve' do
      expect(node(graph, 'ItemList').to_json).not_to include('Sold')
    end
  end
end
