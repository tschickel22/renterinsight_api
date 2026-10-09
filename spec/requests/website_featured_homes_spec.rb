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
end
