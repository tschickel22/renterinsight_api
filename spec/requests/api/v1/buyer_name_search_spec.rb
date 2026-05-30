# frozen_string_literal: true

require 'rails_helper'

# Covers the dispatch "search by buyer name" commit. A vehicle is findable by the name of
# a buyer on a linked deal, on BOTH surfaces — with the field-naming split dispatch flagged:
#   /api/v1/search/global -> matched_buyers (snake_case)
#   /api/v1/vehicles      -> matchedBuyers  (camelCase)
RSpec.describe 'Api::V1 buyer-name vehicle search', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let(:vehicle) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000)
  end
  let(:contact) do
    company.contacts.create!(first_name: 'Maria', last_name: 'Johnson', email: "m-#{SecureRandom.hex(3)}@ex.com")
  end
  let!(:deal) { company.deals.create!(name: 'Johnson deal', contact: contact, vehicle: vehicle) }

  describe 'GET /api/v1/search/global?query=Johnson' do
    it 'returns the vehicle with matched_buyers (snake_case)' do
      get '/api/v1/search/global?query=Johnson', headers: headers
      vresult = JSON.parse(response.body)['results'].find { |r| r['type'] == 'vehicle' && r['id'] == vehicle.id }

      expect(vresult).to be_present
      expect(vresult).to have_key('matched_buyers')
      expect(vresult['matched_buyers'].map { |b| b['name'] }).to include('Maria Johnson')
      expect(vresult['matched_buyers'].first['deal_id']).to eq(deal.id)
    end
  end

  describe 'GET /api/v1/vehicles?search=Johnson' do
    it 'returns the vehicle with matchedBuyers (camelCase)' do
      get '/api/v1/vehicles?search=Johnson', headers: headers
      body = JSON.parse(response.body)
      # vehicle_json serializes id as a string — compare as strings.
      v = body['vehicles'].find { |x| x['id'].to_s == vehicle.id.to_s }

      expect(v).to be_present
      expect(v).to have_key('matchedBuyers')
      expect(v['matchedBuyers'].map { |b| b['name'] }).to include('Maria Johnson')
      expect(v['matchedBuyers'].first['deal_id']).to eq(deal.id)
    end
  end
end
