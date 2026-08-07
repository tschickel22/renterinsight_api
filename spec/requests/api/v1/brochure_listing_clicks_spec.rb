# frozen_string_literal: true

require 'rails_helper'

# Homes on the public brochure page open in place, so the click never reaches
# the server on its own — the page reports it to /b/:public_id/listing_click.
# Attribution rides on the `rt` token that the recipient's own brochure link put
# in the URL.
RSpec.describe 'Brochure listing clicks', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: 'One',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let(:vehicle) do
    company.vehicles.create!(year: 2024, make: 'Clayton', model: 'Rio', status: 'available', vin: "VIN#{SecureRandom.hex(6)}")
  end
  let(:other_vehicle) do
    company.vehicles.create!(year: 2023, make: 'Champion', model: 'Titan', status: 'available', vin: "VIN#{SecureRandom.hex(6)}")
  end
  let(:brochure) do
    Brochure.create!(company_id: company.id, title: 'Fall Collection', status: 'active',
                     is_public: true, vehicle_ids: [vehicle.id, other_vehicle.id])
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Jane', last_name: 'Doe',
                 email: 'jane@x.com', owner_id: user.id)
  end

  # The link we mailed the recipient — its token is what identifies them.
  let(:recipient_link) do
    TrackedLink.create_for_brochure!(
      company: company, brochure: brochure, url: 'https://example.com/b/x',
      entity_type: 'Lead', entity_id: lead.id
    )
  end

  def click(vehicle_id:, rt: nil)
    post "/b/#{brochure.public_id}/listing_click", params: { vehicle_id: vehicle_id, rt: rt }.compact
  end

  describe 'POST /b/:public_id/listing_click' do
    it 'attributes the home click to the recipient the rt token identifies' do
      click(vehicle_id: vehicle.id, rt: recipient_link.token)
      expect(response).to have_http_status(:no_content)

      link = TrackedLink.brochure_listings.last
      expect(link.entity_type).to eq('Lead')
      expect(link.entity_id).to eq(lead.id)
      expect(link.vehicle_id).to eq(vehicle.id)
      expect(link.source_id).to eq(brochure.id)
      expect(link.click_count).to eq(1)
    end

    it 'accumulates repeat clicks on the same home onto one row' do
      3.times { click(vehicle_id: vehicle.id, rt: recipient_link.token) }

      links = TrackedLink.brochure_listings.where(vehicle_id: vehicle.id, entity_id: lead.id)
      expect(links.count).to eq(1)
      expect(links.first.click_count).to eq(3)
    end

    it 'still counts a click with no token, just anonymously' do
      click(vehicle_id: vehicle.id)

      link = TrackedLink.brochure_listings.last
      expect(link.entity_id).to be_nil
      expect(link.click_count).to eq(1)
    end

    it 'refuses a home that is not in this brochure' do
      stranger = company.vehicles.create!(year: 2020, make: 'Other', model: 'Home', status: 'available', vin: "VIN#{SecureRandom.hex(6)}")
      click(vehicle_id: stranger.id, rt: recipient_link.token)

      expect(response).to have_http_status(:not_found)
      expect(TrackedLink.brochure_listings.count).to eq(0)
    end

    it 'ignores an rt token minted for a different brochure' do
      other = Brochure.create!(company_id: company.id, title: 'Other', status: 'active', is_public: true)
      foreign = TrackedLink.create_for_brochure!(
        company: company, brochure: other, url: 'https://example.com/b/y',
        entity_type: 'Lead', entity_id: lead.id
      )

      click(vehicle_id: vehicle.id, rt: foreign.token)

      expect(TrackedLink.brochure_listings.last.entity_id).to be_nil
    end

    it '404s on an unknown brochure' do
      post '/b/nope/listing_click', params: { vehicle_id: vehicle.id }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/brochures/:id/engagement' do
    it 'ranks the homes by clicks and names who is clicking them' do
      recipient_link.record_click!
      2.times { click(vehicle_id: other_vehicle.id, rt: recipient_link.token) }
      5.times { click(vehicle_id: vehicle.id, rt: recipient_link.token) }
      click(vehicle_id: vehicle.id) # anonymous visitor

      get "/api/v1/brochures/#{brochure.id}/engagement", headers: headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)['engagement']
      expect(body['opens']).to eq(1)
      expect(body['home_clicks']).to eq(8)
      expect(body['anonymous_clicks']).to eq(1)

      expect(body['top_homes'].first['vehicle_id']).to eq(vehicle.id)
      expect(body['top_homes'].first['clicks']).to eq(6)
      expect(body['top_homes'].last['vehicle_id']).to eq(other_vehicle.id)

      viewer = body['viewers'].first
      expect(viewer['name']).to eq('Jane Doe')
      expect(viewer['entity_id']).to eq(lead.id)
      expect(viewer['home_clicks']).to eq(7)
      expect(viewer['top_home']['vehicle_id']).to eq(vehicle.id)
      expect(viewer['top_home']['clicks']).to eq(5)
    end

    it 'returns empty engagement for a brochure nobody has touched' do
      get "/api/v1/brochures/#{brochure.id}/engagement", headers: headers

      body = JSON.parse(response.body)['engagement']
      expect(body['opens']).to eq(0)
      expect(body['top_homes']).to eq([])
      expect(body['viewers']).to eq([])
    end
  end
end
