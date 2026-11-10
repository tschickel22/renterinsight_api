# frozen_string_literal: true

require 'rails_helper'

# A dealer hand-picks the homes for a site's Featured Homes section and writes
# copy just for the site. That copy must never reach the inventory record,
# and a sold home must quietly drop off the site without anyone un-picking it.
RSpec.describe 'Website featured homes', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let(:location) { company.locations.create!(name: 'Brooksville') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:auth_headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end
  let(:website) do
    company.websites.create!(location_id: location.id, name: 'Easy', slug: "s-#{SecureRandom.hex(4)}")
  end

  def home(attrs = {})
    Vehicle.create!({ company: company, year: 2025, make: 'Creekside', model: 'Roxy',
                      vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available', is_deleted: false,
                      description: 'From the inventory', images: ['https://cdn.example.com/a.jpg'] }.merge(attrs))
  end

  def save_picks(rows)
    put "/api/v1/websites/#{website.id}/featured_homes",
        params: { featured_homes: rows }.to_json, headers: auth_headers
  end

  def public_featured(params = {})
    get '/public/inventory/featured', params: { token: company.public_inventory_token,
                                                website_id: website.id }.merge(params)
    JSON.parse(response.body)
  end

  describe 'PUT /api/v1/websites/:id/featured_homes' do
    it 'saves the picks in the order given, with site-only copy' do
      first = home(model: 'Dogwood')
      second = home(model: 'Born to Run')

      save_picks([{ vehicle_id: second.id, title: 'Born to Run', description: 'Site copy' },
                  { vehicle_id: first.id }])

      expect(response).to have_http_status(:ok)
      items = JSON.parse(response.body)['items']
      expect(items.map { |i| i['vehicle_id'] }).to eq([second.id, first.id])
      expect(items.first['description']).to eq('Site copy')
      expect(items.last['description']).to be_nil
      expect(items.last['vehicle']['description']).to eq('From the inventory')
    end

    it 'never writes the site copy back to the inventory record' do
      unit = home

      save_picks([{ vehicle_id: unit.id, title: 'New name', description: 'Site copy' }])

      expect(unit.reload.description).to eq('From the inventory')
      expect(unit.model).to eq('Roxy')
    end

    it 'replaces the whole list, so a home left out is un-featured' do
      kept = home
      dropped = home
      save_picks([{ vehicle_id: kept.id }, { vehicle_id: dropped.id }])

      save_picks([{ vehicle_id: kept.id }])

      expect(website.featured_homes.reload.map(&:vehicle_id)).to eq([kept.id])
    end

    it "refuses another company's home" do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      theirs = Vehicle.create!(company: other, year: 2025, make: 'X', model: 'Y',
                               vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available')

      save_picks([{ vehicle_id: theirs.id }])

      expect(response).to have_http_status(:unprocessable_entity)
      expect(website.featured_homes.count).to eq(0)
    end
  end

  describe 'GET /public/inventory/featured' do
    it 'serves the picks in order with the site title and description' do
      a = home(model: 'Dogwood')
      b = home(model: 'Born to Run', description: nil)
      save_picks([{ vehicle_id: b.id, description: 'Two bedrooms' }, { vehicle_id: a.id, title: 'The Dogwood' }])

      body = public_featured

      expect(body['meta']['source']).to eq('picked')
      expect(body['items'].map { |i| i['id'] }).to eq([b.id, a.id])
      expect(body['items'].first['featured_description']).to eq('Two bedrooms')
      expect(body['items'].last['featured_title']).to eq('The Dogwood')
      # Blank site copy falls back to what the inventory says.
      expect(body['items'].last['featured_description']).to eq('From the inventory')
    end

    it 'drops a home that has sold, without anyone un-picking it' do
      sold = home
      for_sale = home
      save_picks([{ vehicle_id: sold.id }, { vehicle_id: for_sale.id }])
      sold.update!(status: 'sold')

      expect(public_featured['items'].map { |i| i['id'] }).to eq([for_sale.id])
    end

    it 'shows the newest homes when nothing has been picked, so the section is never empty' do
      home(model: 'Older').update_column(:created_at, 2.days.ago)
      newest = home(model: 'Newest')

      body = public_featured(limit: 1)

      expect(body['meta']['source']).to eq('newest')
      expect(body['items'].map { |i| i['id'] }).to eq([newest.id])
    end

    it "ignores a website id from another company" do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      other_site = other.websites.create!(location_id: other.locations.create!(name: 'X').id,
                                          name: 'Theirs', slug: "t-#{SecureRandom.hex(4)}")
      theirs = Vehicle.create!(company: other, year: 2025, make: 'X', model: 'Y',
                               vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available')
      other_site.featured_homes.create!(vehicle: theirs, position: 0)
      mine = home

      body = public_featured(website_id: other_site.id)

      expect(body['meta']['source']).to eq('newest')
      expect(body['items'].map { |i| i['id'] }).to eq([mine.id])
    end
  end

  describe 'showing some of the picks at a time' do
    let!(:homes) { Array.new(5) { |i| home(model: "Model #{i}") } }

    before { save_picks(homes.map { |h| { vehicle_id: h.id } }) }

    def save_settings(settings)
      put "/api/v1/websites/#{website.id}/featured_homes",
          params: { featured_homes: homes.map { |h| { vehicle_id: h.id } }, settings: settings }.to_json,
          headers: auth_headers
    end

    it 'shows every pick when no count is set' do
      expect(public_featured['items'].size).to eq(5)
    end

    it 'shows the first few, in order, when rotation is off' do
      save_settings(display_count: 2, rotation: 'off')

      expect(public_featured['items'].map { |i| i['id'] }).to eq(homes.first(2).map(&:id))
    end

    it 'saves and returns the settings, and cleans what it does not know' do
      save_settings(display_count: 99, rotation: 'hourly')

      settings = JSON.parse(response.body)['settings']
      expect(settings).to eq('display_count' => 24, 'rotation' => 'off')
    end

    it 'steps through every pick a day at a time, wrapping round' do
      picks = website.featured_homes.reload.to_a
      settings = { 'display_count' => 2, 'rotation' => 'day' }
      day = Date.new(2026, 10, 9)

      shown = (0...5).map { |n| WebsiteFeaturedHome.rotate(picks, settings, today: day + n).map(&:vehicle_id) }

      expect(shown.flatten.uniq).to match_array(homes.map(&:id))
      expect(WebsiteFeaturedHome.rotate(picks, settings, today: day)).to eq(WebsiteFeaturedHome.rotate(picks, settings, today: day))
    end

    it 'keeps the dealer order inside a fresh-every-visit handful' do
      picks = website.featured_homes.reload.to_a

      shown = WebsiteFeaturedHome.rotate(picks, { 'display_count' => 3, 'rotation' => 'visit' }, rng: Random.new(1))

      expect(shown.size).to eq(3)
      expect(shown.map(&:position)).to eq(shown.map(&:position).sort)
    end
  end

  describe 'whether the site uses the section' do
    it 'says so only when a page has a Featured Homes block' do
      get "/api/v1/websites/#{website.id}/featured_homes", headers: auth_headers
      expect(JSON.parse(response.body)['in_use']).to be false

      website.website_pages.create!(title: 'Home', path: '/', blocks: [{ 'type' => 'featuredHomes', 'content' => {} }])
      get "/api/v1/websites/#{website.id}/featured_homes", headers: auth_headers
      expect(JSON.parse(response.body)['in_use']).to be true
    end
  end

  # Tom 2026-11-10: a featured home can show its sale (was, now, a callout)
  # while the sale's dates are good. Price and sale are the inventory record,
  # so editing them here edits the home.
  describe 'sale pricing on a featured home' do
    let(:today) { Time.current.in_time_zone('America/New_York').to_date }

    def on_sale(attrs = {})
      home({ msrp: 100_000, special_discount_enabled: true, discount_type: '$ Flat Amount', discount_value: 7_000,
             overlay_text: 'Hot Home' }.merge(attrs))
    end

    it 'shows was, now and the callout only where the switch is on' do
      shown = on_sale(model: 'Shown')
      hidden = on_sale(model: 'Hidden')
      save_picks([{ vehicle_id: shown.id, show_sale: true }, { vehicle_id: hidden.id }])

      items = public_featured['items'].index_by { |i| i['id'] }
      expect(items[shown.id]['featured_sale']).to include('was' => 100_000.0, 'now' => 93_000.0, 'callout' => 'Hot Home', 'ends_on' => nil)
      expect(items[hidden.id]['featured_sale']).to be_nil
    end

    it 'waits for the start day and stops after the end day; no end day stays open' do
      later = on_sale(model: 'Later', special_discount_starts_on: today + 3)
      ended = on_sale(model: 'Ended', special_discount_starts_on: today - 10, special_discount_ends_on: today - 1)
      open_ended = on_sale(model: 'Open', special_discount_starts_on: today - 10)
      save_picks([later, ended, open_ended].map { |v| { vehicle_id: v.id, show_sale: true } })

      items = public_featured['items'].index_by { |i| i['id'] }
      expect(items[later.id]['featured_sale']).to be_nil
      expect(items[later.id]['sale_price']).to be_nil
      expect(items[ended.id]['featured_sale']).to be_nil
      expect(items[open_ended.id]['featured_sale']).to include('now' => 93_000.0)
    end

    it 'writes price and sale edits to the inventory home' do
      v = home(msrp: 80_000)
      save_picks([{ vehicle_id: v.id, show_sale: true,
                    pricing: { msrp: 90_000, special_discount_enabled: true, discount_type: '$ Flat Amount', discount_value: 5_000,
                               special_discount_starts_on: today.iso8601, special_discount_ends_on: '', overlay_text: ' Only this month ' } }])

      expect(response).to have_http_status(:ok)
      v.reload
      expect([v.msrp.to_f, v.discounted_price.to_f, v.special_discount_starts_on, v.special_discount_ends_on, v.overlay_text])
        .to eq([90_000.0, 85_000.0, today, nil, 'Only this month'])
      item = JSON.parse(response.body)['items'].first
      expect(item['show_sale']).to be(true)
      expect(item['vehicle']['sale_now']).to include('was' => 90_000.0, 'now' => 85_000.0)
    end

    it 'refuses an end day before the start day' do
      v = home(msrp: 80_000)
      save_picks([{ vehicle_id: v.id, pricing: { special_discount_enabled: true, discount_type: '$ Flat Amount', discount_value: 1,
                                                 special_discount_starts_on: (today + 5).iso8601, special_discount_ends_on: today.iso8601 } }])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(v.reload.special_discount_enabled).to be(false)
    end
  end
end
