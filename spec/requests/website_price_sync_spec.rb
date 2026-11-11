# frozen_string_literal: true

require 'rails_helper'

# Tom 2026-11-11: a website's "Show asking prices" switch and TrueBuild
# "What buyers see" stay in step, whichever screen changes.
RSpec.describe 'Website prices and TrueBuild What buyers see in sync', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true })
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) # TrueBuild on the plan
    end
  end
  let(:location) { company.locations.create!(name: 'Lot') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let!(:site) { company.websites.create!(location_id: location.id, name: 'One', slug: "one-#{SecureRandom.hex(4)}") }
  let!(:other) { company.websites.create!(location_id: location.id, name: 'Two', slug: "two-#{SecureRandom.hex(4)}") }

  def display = DealerCatalogTerm.effective(company, nil).price_display

  def save_site(settings)
    put "/api/v1/websites/#{site.id}/inventory_settings", params: { inventory_settings: settings }.to_json, headers: headers
    JSON.parse(response.body)
  end

  def save_terms(body)
    put '/api/v1/truebuild_pricing/terms', params: body.to_json, headers: headers
    JSON.parse(response.body)
  end

  describe 'from the site switch' do
    it 'turning it off hides TrueBuild prices; on again shows full prices' do
      company.dealer_catalog_terms.create!(manufacturer_id: nil, price_display: 'starting_at')
      site.update!(inventory_settings: { 'show_prices' => true })

      body = save_site(show_prices: false)
      expect(body['price_display_changed']).to eq('from' => 'starting_at', 'to' => 'hidden')
      expect(display).to eq('hidden')

      body = save_site(show_prices: true)
      expect(body['price_display_changed']).to eq('from' => 'hidden', 'to' => 'full')
      expect(display).to eq('full')
    end

    it 'keeps a shown choice such as monthly when turned on, and changes nothing when the switch did not move' do
      company.dealer_catalog_terms.create!(manufacturer_id: nil, price_display: 'monthly')
      site.update!(inventory_settings: { 'show_prices' => false })

      expect(save_site(show_prices: true)['price_display_changed']).to be_nil
      expect(display).to eq('monthly')
      expect(save_site(hide_rules: [])['price_display_changed']).to be_nil
    end
  end

  describe 'from TrueBuild What buyers see' do
    it 'hidden turns every website off, shown turns them on and lets the price list hold go' do
      site.update!(inventory_settings: { 'show_prices' => true, 'price_list_held' => true, 'featured_price_held' => true })
      other.update!(inventory_settings: { 'show_prices' => true })
      company.dealer_catalog_terms.create!(manufacturer_id: nil, price_display: 'full')

      body = save_terms(manufacturer_id: nil, price_display: 'hidden')
      expect(body['websites_changed']).to eq(2)
      expect([site, other].map { |w| Websites::InventorySettings.new(w.reload).show_prices? }).to eq([false, false])

      body = save_terms(manufacturer_id: nil, price_display: 'starting_at')
      expect(body).to include('websites_changed' => 2, 'websites_show_prices' => true)
      settings = Websites::InventorySettings.new(site.reload)
      expect(settings.show_prices?).to be(true)
      expect(settings.price_list_held?).to be(false)
      expect(settings.featured_price_held?).to be(true)
    end

    it 'leaves websites alone when What buyers see did not change or another field was saved' do
      company.dealer_catalog_terms.create!(manufacturer_id: nil, price_display: 'hidden')
      site.update!(inventory_settings: { 'show_prices' => true })

      body = save_terms(manufacturer_id: nil, price_display: 'hidden', round_retail_to: 100)
      expect(body).not_to have_key('websites_changed')
      expect(Websites::InventorySettings.new(site.reload).show_prices?).to be(true)
    end

    it 'reports how many websites the setting reaches' do
      get '/api/v1/truebuild_pricing', headers: headers
      expect(JSON.parse(response.body)['websites_count']).to eq(2)
    end
  end
end
