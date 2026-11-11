# frozen_string_literal: true

require 'rails_helper'

# Edit Website, Inventory tab (Tom 2026-11-11): one "Show asking prices"
# switch per site, rules and single-home switches that hide homes from that
# site only, and a homes list. Hidden homes never leave the public API for
# that site; a Featured Homes sale the dealer chose to show still shows when
# prices are off.
RSpec.describe 'Website inventory settings', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true, 'show_pricing' => true,
                                             'public_statuses' => %w[available available_to_order] })
    end
  end
  let(:location) { company.locations.create!(name: 'Lot') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end
  let(:site) { company.websites.create!(location_id: location.id, name: 'One', slug: "one-#{SecureRandom.hex(4)}") }
  let(:other_site) { company.websites.create!(location_id: location.id, name: 'Two', slug: "two-#{SecureRandom.hex(4)}") }

  def home(attrs = {})
    Vehicle.create!({ company: company, year: 2025, make: 'Clayton', model: 'Willowbrook', msrp: 112_976,
                      vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available', is_deleted: false,
                      listing_type: 'manufactured_home', bedrooms: 3, bathrooms: 2 }.merge(attrs))
  end

  def save(settings, website = site)
    put "/api/v1/websites/#{website.id}/inventory_settings", params: { inventory_settings: settings }.to_json, headers: headers
  end

  def public_list(website)
    get '/public/inventory', params: { token: company.public_inventory_token, website_id: website.id }
    JSON.parse(response.body)['items']
  end

  describe 'PUT /api/v1/websites/:id/inventory_settings' do
    it 'saves the switch, rules and hidden homes for this site only' do
      unit = home
      save(show_prices: false, hide_rules: [{ field: 'make', value: ' Winnebago ' }, { field: 'bogus', value: 'x' }],
           hidden_vehicle_ids: [unit.id])

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['settings']).to include('show_prices' => false, 'hidden_vehicle_ids' => [unit.id])
      expect(body['settings']['hide_rules']).to eq([{ 'field' => 'make', 'value' => 'Winnebago' }])
      expect(site.reload.inventory_settings['show_prices']).to be(false)
      expect(other_site.reload.inventory_settings).to eq({})
    end

    it "drops another company's home from the hidden list" do
      stranger = Company.create!(name: 'Other')
      theirs = Vehicle.create!(company: stranger, year: 2024, make: 'X', model: 'Y', vin: "V#{SecureRandom.hex(6)}", status: 'available')
      save(hidden_vehicle_ids: [theirs.id])
      expect(JSON.parse(response.body)['settings']['hidden_vehicle_ids']).to eq([])
    end

    it 'refuses someone who may not edit websites' do
      allow_any_instance_of(Api::V1::WebsiteInventoryController).to receive(:authorize_action!) do |ctrl, _res, action|
        next true if action == 'read'

        ctrl.render(json: { error: 'Permission denied' }, status: :forbidden)
        false
      end
      save(show_prices: false)
      expect(response).to have_http_status(:forbidden)
      expect(site.reload.inventory_settings).to eq({})
    end
  end

  describe 'public inventory' do
    it 'leaves out homes a rule or a switch hides on this site, but not on another site of the company' do
      kept = home(make: 'Clayton')
      by_rule = home(make: 'Winnebago', model: 'Jay Flight')
      by_switch = home(make: 'Fleetwood', model: 'Pinehurst')
      save(show_prices: true, hide_rules: [{ field: 'make', value: 'winnebago' }], hidden_vehicle_ids: [by_switch.id])

      ids = public_list(site).map { |i| i['id'] }
      expect(ids).to include(kept.id)
      expect(ids).not_to include(by_rule.id, by_switch.id)

      expect(public_list(other_site).map { |i| i['id'] }).to include(kept.id, by_rule.id, by_switch.id)

      get "/public/inventory/#{by_rule.id}", params: { token: company.public_inventory_token, website_id: site.id }
      expect(response).to have_http_status(:not_found)
      get "/public/inventory/#{by_rule.id}", params: { token: company.public_inventory_token, website_id: other_site.id }
      expect(response).to have_http_status(:ok)

      get '/public/inventory/filters', params: { token: company.public_inventory_token, website_id: site.id }
      expect(JSON.parse(response.body).to_s).not_to include('Winnebago')
    end

    it 'hides by series and status too' do
      mfr = Manufacturer.create!(name: "M #{SecureRandom.hex(3)}", industry_type: 'manufactured_home')
      plan = CatalogPlan.create!(manufacturer: mfr, series: 'Embrace', name: 'Plan')
      variant = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: "E#{SecureRandom.hex(3)}", building_code: BuildingCode::HUD)
      embrace = home(catalog_plan_variant_id: variant.id)
      to_order = home(status: 'available_to_order')
      plain = home
      save(hide_rules: [{ field: 'series', value: 'EMBRACE' }, { field: 'status', value: 'available_to_order' }])

      get '/public/inventory', params: { token: company.public_inventory_token, website_id: site.id, statuses: 'available,available_to_order' }
      ids = JSON.parse(response.body)['items'].map { |i| i['id'] }
      expect(ids).to include(plain.id)
      expect(ids).not_to include(embrace.id, to_order.id)
    end

    it 'sends no prices when the switch is off, and prices when it is on' do
      unit = home(msrp: 99_000, rent_price: 900)
      save(show_prices: false)
      item = public_list(site).find { |i| i['id'] == unit.id }
      expect(item.values_at('price', 'base_price', 'sale_price', 'rent_price', 'total_home_price', 'monthly_payment')).to all(be_nil)

      get "/public/inventory/#{unit.id}", params: { token: company.public_inventory_token, website_id: site.id }
      detail = JSON.parse(response.body)['vehicle']
      expect(detail.values_at('price', 'msrp', 'total_home_price', 'total_price_before_discount')).to all(be_nil)

      save(show_prices: true)
      item = public_list(site).find { |i| i['id'] == unit.id }
      expect(item['price']).to eq(99_000.0)
      expect(item['base_price']).to eq(99_000.0)
    end

    it 'still shows a Featured Homes sale the dealer turned on when prices are off' do
      unit = home(msrp: 160_000, special_discount_enabled: true, discount_type: '$ Flat Amount', discount_value: 10_000)
      site.featured_homes.create!(vehicle: unit, position: 0, show_sale: true)
      save(show_prices: false)

      get '/public/inventory/featured', params: { token: company.public_inventory_token, website_id: site.id }
      item = JSON.parse(response.body)['items'].find { |i| i['id'] == unit.id }
      expect(item['price']).to be_nil
      expect(item['featured_sale']).to include('now' => 150_000.0, 'was' => 160_000.0)
    end

    it 'keeps the company-wide behavior with no site' do
      unit = home(msrp: 50_000)
      save(show_prices: false, hidden_vehicle_ids: [unit.id])
      get '/public/inventory', params: { token: company.public_inventory_token }
      item = JSON.parse(response.body)['items'].find { |i| i['id'] == unit.id }
      expect(item['price']).to eq(50_000.0)
    end
  end

  describe 'a site saved before the switch existed' do
    def page_with(blocks)
      site.website_pages.create!(title: 'Home', path: "/home-#{SecureRandom.hex(3)}", blocks: blocks)
    end

    it 'shows what its inventory sections showed' do
      page_with([{ 'type' => 'inventory', 'content' => { 'showPricing' => false } }])
      expect(Websites::InventorySettings.new(site.reload).show_prices?).to be(false)

      page_with([{ 'type' => 'inventory', 'content' => {} }])
      expect(Websites::InventorySettings.new(site.reload).show_prices?).to be(true)
    end

    it 'holds price list prices back while TrueBuild prices are hidden, until the dealer releases them' do
      page_with([{ 'type' => 'inventory', 'content' => { 'showPricing' => true } }])
      expect(Websites::InventorySettings.new(site.reload).price_list_held?).to be(true) # price_display defaults to hidden

      save(hidden_vehicle_ids: [])
      expect(JSON.parse(response.body)['settings']).to include('show_prices' => true, 'price_list_held' => true)

      save(release_price_list: true)
      expect(JSON.parse(response.body)['settings']).to include('show_prices' => true, 'price_list_held' => false)
      expect(Websites::InventorySettings.new(site.reload).designer_prices).to be(true)
    end

    it 'keeps Featured Homes cards without a price when their section had Show price off' do
      company.dealer_catalog_terms.create!(manufacturer_id: nil, price_display: 'full')
      page_with([{ 'type' => 'inventory', 'content' => {} }, { 'type' => 'featuredHomes', 'content' => {} }])
      settings = Websites::InventorySettings.new(site.reload)
      expect(settings.public_h).to eq(show_prices: true, featured_price_held: true)
      expect(settings.designer_prices).to be(true)

      save(show_prices: false)
      save(show_prices: true)
      expect(JSON.parse(response.body)['settings']).to include('featured_price_held' => false, 'price_list_held' => false)
    end

    it 'hides the TrueBuild design page prices when the switch is off' do
      save(show_prices: false)
      expect(Websites::InventorySettings.new(site.reload).designer_prices).to be(false)
    end
  end

  describe 'GET /api/v1/websites/:id/inventory_homes' do
    it 'lists the homes with asking price, source, and why one is hidden' do
      typed = home(make: 'Clayton', msrp: 112_976)
      ruled = home(make: 'Winnebago', model: 'Jay Flight', msrp: 132_245)
      save(show_prices: false, hide_rules: [{ field: 'make', value: 'Winnebago' }])

      get "/api/v1/websites/#{site.id}/inventory_homes", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      row = body['items'].find { |i| i['id'] == typed.id }
      expect(row['asking_price']).to include('source' => 'home')
      expect(row['public_price']).to include('amount' => 112_976.0)
      expect(body['items'].find { |i| i['id'] == ruled.id }['hidden_by_rule']).to eq('field' => 'make', 'value' => 'Winnebago')
      expect(body['meta']).to include('total' => 2, 'shown' => 1, 'hidden' => 1)

      get "/api/v1/websites/#{site.id}/inventory_homes", params: { search: 'jay' }, headers: headers
      expect(JSON.parse(response.body)['items'].map { |i| i['id'] }).to eq([ruled.id])
    end
  end
end
