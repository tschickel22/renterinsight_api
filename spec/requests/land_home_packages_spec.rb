# frozen_string_literal: true

require 'rails_helper'

# A lot and a home offered together at one price, paired from Land
# Management and shown on the dealer's website.
RSpec.describe 'Land + home packages', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing').tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(16),
                public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@x.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  def lot(attrs = {})
    LandParcel.create!({ company: company, name: 'Lot 7', acreage: 1.5, price: 40_000, status: 'available',
                         city: 'Brooksville', state: 'FL', images: ['https://cdn.example.com/lot.jpg'] }.merge(attrs))
  end

  def home(attrs = {}, owner = company)
    Vehicle.create!({ company: owner, year: 2026, make: 'Kabco', model: 'Rubicon', listing_type: 'manufactured_home',
                      vin: "VIN#{SecureRandom.hex(6).upcase}", serial_number: "SN#{SecureRandom.hex(5).upcase}",
                      status: 'available', is_deleted: false, bedrooms: 4, bathrooms: 2, square_feet: 2280,
                      sale_price: 120_000, images: ['https://cdn.example.com/home.jpg'] }.merge(attrs))
  end

  def create_package(params)
    post '/api/v1/land-home-packages', params: { package: params }.to_json, headers: headers
    JSON.parse(response.body)
  end

  describe 'pairing a home with a lot' do
    it 'prices the package at the lot plus the home unless told otherwise' do
      body = create_package(land_parcel_id: lot.id, vehicle_id: home.id, description: 'Turnkey')

      expect(response).to have_http_status(:created)
      expect(body['package']['price']).to eq(160_000.0)
      expect(body['package']['suggested_price']).to eq(160_000.0)
      expect(body['package']['display_name']).to eq('2026 Kabco Rubicon on Lot 7')
    end

    it 'suggests no total while the home has no price, rather than the lot alone' do
      body = create_package(land_parcel_id: lot.id, vehicle_id: home(sale_price: nil, msrp: nil).id)

      expect(response).to have_http_status(:created)
      expect(body['package']['suggested_price']).to be_nil
      expect(body['package']['price']).to be_nil
    end

    it 'keeps a price the dealer sets' do
      body = create_package(land_parcel_id: lot.id, vehicle_id: home.id, price: 149_900)
      expect(body['package']['price']).to eq(149_900.0)
    end

    it 'offers one lot with several homes, but each home once' do
      parcel = lot
      create_package(land_parcel_id: parcel.id, vehicle_id: home.id)
      create_package(land_parcel_id: parcel.id, vehicle_id: home(model: 'Windsor').id)
      expect(parcel.land_home_packages.count).to eq(2)

      again = parcel.land_home_packages.first.vehicle_id
      create_package(land_parcel_id: parcel.id, vehicle_id: again)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses another company's home or lot" do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      create_package(land_parcel_id: lot.id, vehicle_id: home({}, other).id)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(LandHomePackage.count).to eq(0)
    end

    it 'edits and removes a package, and never moves it to another company' do
      id = create_package(land_parcel_id: lot.id, vehicle_id: home.id)['package']['id']
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")

      patch "/api/v1/land-home-packages/#{id}",
            params: { package: { name: 'The Complete Home', show_on_website: false, company_id: other.id } }.to_json,
            headers: headers
      package = LandHomePackage.find(id)
      expect(package.name).to eq('The Complete Home')
      expect(package.show_on_website).to be false
      expect(package.company_id).to eq(company.id)

      delete "/api/v1/land-home-packages/#{id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(LandHomePackage.exists?(id)).to be false
    end

    it 'lists a lot’s packages' do
      parcel = lot
      create_package(land_parcel_id: parcel.id, vehicle_id: home.id)
      create_package(land_parcel_id: lot(name: 'Lot 9').id, vehicle_id: home(model: 'Windsor').id)

      get '/api/v1/land-home-packages', params: { land_parcel_id: parcel.id }, headers: headers
      expect(JSON.parse(response.body)['packages'].size).to eq(1)
    end
  end

  describe 'on the website' do
    def public_packages
      get '/public/land_home_packages', params: { token: company.public_inventory_token },
                                        headers: { 'Origin' => 'https://easy-homesource-2.mydealertide.com' }
      JSON.parse(response.body)['items']
    end

    it 'shows packages with the home, the lot and their photos' do
      create_package(land_parcel_id: lot.id, vehicle_id: home.id, description: 'Turnkey')

      item = public_packages.first
      expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
      expect(item).to include('title' => '2026 Kabco Rubicon on Lot 7', 'price' => 160_000.0, 'description' => 'Turnkey')
      expect(item['home']).to include('bedrooms' => 4, 'square_feet' => 2280)
      expect(item['land']).to include('acreage' => 1.5, 'city' => 'Brooksville')
      expect(item['images']).to eq(['https://cdn.example.com/home.jpg', 'https://cdn.example.com/lot.jpg'])
    end

    it 'drops a package when the lot or the home sells, or it is switched off' do
      sold_lot = lot(name: 'Sold lot')
      sold_home = home(model: 'Sold')
      off = home(model: 'Off')
      shown = home(model: 'Shown')
      create_package(land_parcel_id: sold_lot.id, vehicle_id: shown.id)
      create_package(land_parcel_id: lot.id, vehicle_id: sold_home.id)
      off_id = create_package(land_parcel_id: lot(name: 'Lot 8').id, vehicle_id: off.id)['package']['id']
      create_package(land_parcel_id: lot(name: 'Lot 9').id, vehicle_id: shown.id)
      sold_lot.update!(status: 'sold')
      sold_home.update!(status: 'sold')
      LandHomePackage.find(off_id).update!(show_on_website: false)

      expect(public_packages.map { |i| i['title'] }).to eq(['2026 Kabco Shown on Lot 9'])
    end

    it 'refuses a wrong token' do
      get '/public/land_home_packages', params: { token: 'nope' }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'the land list' do
    it 'ignores a sort it does not know rather than putting it in the query' do
      lot
      get '/api/v1/land-parcels', params: { sort_by: 'price; DROP TABLE land_parcels', sort_order: 'desc' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(LandParcel.count).to eq(1)
    end
  end
end
