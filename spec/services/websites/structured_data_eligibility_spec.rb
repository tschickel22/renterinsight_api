# frozen_string_literal: true

require 'rails_helper'

# The regression gate on our own markup.
#
# A gap on a prospect's site is a reason to call them. The same gap on a site we
# built is a defect, and this is where it should fail: before deploy, rather
# than on a dealer's live site afterwards. Google publishes no API for the Rich
# Results Test, so these are its documented requirements encoded in
# Seo::RichResultRules and pointed at our own output.
#
# Deliberately split in two. Given a dealer who has filled everything in, our
# markup must be flawless, and anything failing here is ours to fix. Given a
# dealer who has not, the only things missing must be the ones that depend on
# what they entered, which is how we tell "we have a bug" from "they have not
# set a price".
RSpec.describe 'the markup our builder emits', type: :model do
  def nodes_for(website:, page: nil, vehicle: nil)
    Websites::StructuredData.new(website: website, page: page,
                                 canonical_host: 'summitpark.example.com', vehicle: vehicle).graph
  end

  def issues(**args)
    Seo::RichResultRules.issues_for(nodes_for(**args))
  end

  let(:company) do
    Company.create!(name: 'Summit Park Homes', phone: '555-0100', email: 'sales@summit.test',
                    address_line1: '100 Lot Road', city: 'Denver', state: 'CO', zip_code: '80231',
                    industry: 'manufactured_housing')
  end
  let(:location) do
    company.locations.create!(
      name: 'Denver Showroom', address_line1: '100 Lot Road', city: 'Denver', state: 'CO',
      zip_code: '80231', phone: '555-0100',
      business_hours: { 'monday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false } }
    )
  end
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit Park',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published',
                    brand: { 'company_name' => 'Summit Park Homes',
                             'logo_url' => 'https://cdn.test/logo.png' })
  end

  def home(**attrs)
    company.vehicles.create!({
      vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes', model: 'Prairie Dune',
      status: 'available', bedrooms: 3, bathrooms: 2, square_feet: 1023, sale_price: 89_900,
      images: [{ 'url' => 'https://cdn.test/front.jpg' }]
    }.merge(attrs))
  end

  describe 'a dealer who has filled everything in' do
    it 'emits a listing eligible for a product result' do
      expect(issues(website: website, vehicle: home)).to be_empty
    end

    it 'emits a dealership eligible for local results' do
      home # the price range and fallback image are read off the lot
      expect(issues(website: website)).to be_empty
    end
  end

  # Anything here is ours, not theirs, and the point of the split.
  describe 'nothing missing is ever our fault' do
    it 'never omits a property we control, whatever the dealer left blank' do
      bare_company = Company.create!(name: 'Bare Co', address_line1: '9 Empty Road')
      bare_site = Website.create!(company_id: bare_company.id,
                                  location_id: bare_company.locations.create!(name: 'Lot').id,
                                  name: 'Bare', slug: "s-#{SecureRandom.hex(4)}", status: 'published')
      priceless = bare_company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026,
                                                make: 'Skyline', model: 'A', status: 'available')

      ours = issues(website: bare_site, vehicle: priceless).select { |i| i.source == :markup }

      expect(ours).to be_empty, "we failed to emit: #{ours.map(&:property).join(', ')}"
    end

    # The live case: a lot where no home has a price. The listing is genuinely
    # ineligible and that is the dealer's to fix, but it must be reported as
    # theirs rather than logged as our defect.
    it 'attributes a missing price to the dealer, not to the builder' do
      bare_company = Company.create!(name: 'No Price Co', address_line1: '9 Empty Road',
                                     zip_code: '80231')
      bare_site = Website.create!(company_id: bare_company.id,
                                  location_id: bare_company.locations.create!(name: 'Lot').id,
                                  name: 'NoPrice', slug: "s-#{SecureRandom.hex(4)}", status: 'published')
      priceless = bare_company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline',
                                                model: 'A', status: 'available',
                                                images: [{ 'url' => 'https://cdn.test/a.jpg' }])

      found = issues(website: bare_site, vehicle: priceless)

      # One finding, not four. With no price we emit no offer node at all, so
      # the currency and availability we never reached are not separate faults.
      expect(found.select(&:required?).map(&:property)).to eq(['offers'])
      expect(found.select(&:required?).map(&:source).uniq).to eq([:data])
    end
  end

  describe 'the pages a buyer actually lands on' do
    it 'keeps a brochure page eligible' do
      page = website.website_pages.create!(title: 'Inventory', path: '/inventory', order: 1)
      home

      expect(issues(website: website, page: page)).to be_empty
    end
  end
end
