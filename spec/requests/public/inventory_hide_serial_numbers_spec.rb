# frozen_string_literal: true

require 'rails_helper'

# A dealer can keep serial numbers and VINs off the web. The values must leave
# the public answer itself: hiding them only on the page would still publish
# them to anyone reading the response.
RSpec.describe 'Public inventory hides serial numbers', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true, 'public_statuses' => %w[available] })
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
  let!(:site) { company.websites.create!(location_id: location.id, name: 'One', slug: "one-#{SecureRandom.hex(4)}") }
  let!(:home) do
    Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Serial Test', vin: 'VINSECRET123',
                    serial_number: 'SERIALSECRET456', status: 'available', is_deleted: false,
                    listing_type: 'manufactured_home', bedrooms: 3, bathrooms: 2, msrp: 80_000)
  end

  def detail(params = {})
    get "/public/inventory/#{home.id}", params: { token: company.public_inventory_token }.merge(params)
    expect(response).to have_http_status(:ok)
    response.body
  end

  it 'still sends them when the setting is off' do
    expect(detail).to include('VINSECRET123', 'SERIALSECRET456')
  end

  context 'with the setting on' do
    before { site.update!(inventory_settings: { 'hide_serial_numbers' => true }) }

    it 'leaves them out whether or not the request names the site' do
      [detail, detail(website_id: site.id)].each do |body|
        expect(body).not_to include('VINSECRET123')
        expect(body).not_to include('SERIALSECRET456')
      end
    end

    it 'leaves the VIN out of the search engine markup' do
      markup = -> { Websites::StructuredData.new(website: site, page: nil, canonical_host: 'example.com', vehicle: home).to_tag }
      expect(markup.call).not_to include('VINSECRET123')

      site.update!(inventory_settings: {})
      expect(markup.call).to include('VINSECRET123')
    end

    it 'does not touch another dealer' do
      expect(Websites::InventorySettings.serials_hidden?(Company.create!(name: "Other-#{SecureRandom.hex(4)}"))).to be(false)
    end

    it 'stays on after the Inventory tab saves' do
      put "/api/v1/websites/#{site.id}/inventory_settings", params: { inventory_settings: { hide_rules: [] } }.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(site.reload.inventory_settings['hide_serial_numbers']).to be(true)
    end

    it 'turns off from the Inventory tab' do
      put "/api/v1/websites/#{site.id}/inventory_settings", params: { inventory_settings: { hide_serial_numbers: false } }.to_json, headers: headers
      expect(JSON.parse(response.body).dig('settings', 'hide_serial_numbers')).to be(false)
      expect(detail).to include('SERIALSECRET456')
    end
  end
end
