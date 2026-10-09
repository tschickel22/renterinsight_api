# frozen_string_literal: true

require 'rails_helper'

# A quote can show the home (backlog E73): its photos, floor plan and facts,
# never a price, on the buyer's link and in the PDF. A lot home shows its own
# photos, or its model's; a home to be built from the Deal Sheet, the model's.
RSpec.describe 'The home on a quote', type: :request do
  let(:company) { create(:company) }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, series: 'Aspire', name: 'Bay Port') }
  let(:variant) do
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56, beds: 3, baths: 2,
                               media: { 'photos' => [{ 'url' => 'https://s7d9.scene7.com/is/image/championhomes/bay-port-kitchen' }],
                                        'floor_plans' => ['https://s7d9.scene7.com/is/image/championhomes/Main_0002_2856H32168-'] })
  end
  # A 1x1 PNG: the PDF draws whatever the image service sends, when it is JPEG or PNG.
  let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }

  def quote_for(vehicle: nil, show: true)
    Quote.create!(company: company, status: 'sent', subtotal: 80_000, tax: 0, total: 80_000, vehicle: vehicle, show_home: show,
                  items: [{ 'description' => 'Bay Port 2856H32168', 'quantity' => 1, 'unit_price' => 80_000, 'total' => 80_000 }])
  end

  it "shows a lot home's own photos and facts, or its model's when it has none, and no price" do
    own = Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Bay Port', vin: "V#{SecureRandom.hex(5)}", status: 'available',
                          is_deleted: false, bedrooms: 3, bathrooms: 2, square_feet: 1493, catalog_plan_variant: variant,
                          images: [{ 'url' => 'https://cdn.example.com/lot/bay-port-front.jpg' }], features: ['Kitchen island', 'Walk-in shower'])
    get "/q/#{quote_for(vehicle: own).public_token}"
    home = response.parsed_body['quote']['home']
    expect(home).to include('title' => '2026 Champion Bay Port', 'bedrooms' => 3, 'square_feet' => 1493,
                            'photos' => ['https://cdn.example.com/lot/bay-port-front.jpg'], 'features' => ['Kitchen island', 'Walk-in shower'])
    expect(home['floor_plans']).to eq(['https://s7d9.scene7.com/is/image/championhomes/Main_0002_2856H32168-'])
    expect(home.keys.grep(/price|cost/i)).to be_empty

    bare = Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Bay Port', vin: "V#{SecureRandom.hex(5)}", status: 'available',
                           is_deleted: false, bedrooms: 3, bathrooms: 2, catalog_plan_variant: variant)
    get "/q/#{quote_for(vehicle: bare).public_token}"
    expect(response.parsed_body['quote']['home']['photos']).to eq(['https://s7d9.scene7.com/is/image/championhomes/bay-port-kitchen'])

    get "/q/#{quote_for(vehicle: bare, show: false).public_token}"
    expect(response.parsed_body['quote']).not_to have_key('home')
  end

  it 'prints the quote on its own, then the home on the next page with three photos and the floor plan' do
    photos = %w[front kitchen bath bedroom].map { |r| { 'url' => "https://s7d9.scene7.com/is/image/championhomes/bay-port-#{r}" } }
    variant.update!(media: variant.media.merge('photos' => photos))
    home = Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Bay Port', vin: "V#{SecureRandom.hex(5)}", status: 'available',
                           is_deleted: false, bedrooms: 3, bathrooms: 2, catalog_plan_variant: variant)
    asked = []
    allow_any_instance_of(QuotePdfGenerator).to receive(:load_logo) { |_, url| asked << url; png }
    pages = PDF::Reader.new(StringIO.new(QuotePdfGenerator.new(quote_for(vehicle: home)).generate)).pages.map(&:text)
    expect(pages.size).to eq(2)
    expect(pages[0]).to include('Bay Port 2856H32168')
    expect(pages[0]).not_to include('The home')
    expect(pages[1]).to include('The home', '2026 Champion Bay Port', '3 bed', 'Floor plan')
    expect(asked).to include('https://s7d9.scene7.com/is/image/championhomes/bay-port-front?fmt=jpg&wid=1400')
    expect(asked.grep(/bay-port-bedroom/)).to be_empty # three photos, not four
  end

  it "shows the Deal Sheet's home, not a different home the deal still names" do
    contact = company.contacts.create!(first_name: 'A', last_name: 'B', email: 'ab@example.com')
    deal = company.deals.create!(name: 'Order', contact_id: contact.id)
    build = DealHomeBuild.create!(company: company, deal: deal, variant: variant, source: 'order', version_number: 1, live: true)
    other = Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Prairie Dune 8710', vin: "V#{SecureRandom.hex(5)}", status: 'available',
                            is_deleted: false, bedrooms: 3, bathrooms: 2, images: [{ 'url' => 'https://s7d9.scene7.com/is/image/championhomes/prairie-main' }])
    quote = quote_for(vehicle: other).tap { |q| q.update!(deal: deal, deal_home_build: build) }
    get "/q/#{quote.public_token}"
    home = response.parsed_body['quote']['home']
    expect(home['title']).to include('Bay Port', '2856H32168')
    expect(home['photos']).to eq(['https://s7d9.scene7.com/is/image/championhomes/bay-port-kitchen'])
    expect(home['floor_plans']).to eq(['https://s7d9.scene7.com/is/image/championhomes/Main_0002_2856H32168-'])
  end

  it 'refuses a Deal Sheet of another deal' do
    other = create(:company)
    contact = other.contacts.create!(first_name: 'A', last_name: 'B', email: 'ab@example.com')
    deal = other.deals.create!(name: 'Theirs', contact_id: contact.id)
    build = DealHomeBuild.create!(company: other, deal: deal, variant: variant, source: 'order', version_number: 1, live: true)
    quote = Quote.new(company: company, status: 'draft', subtotal: 0, tax: 0, total: 0, items: [], deal_home_build_id: build.id)
    expect(quote).not_to be_valid
    expect(quote.errors[:deal_home_build_id]).to be_present
  end
end
