# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/fake_catalog_adapter')

RSpec.describe 'Editing a catalog home', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:source) { create(:catalog_source) }
  let(:mine) { ['https://lot.example/mine.jpg'] }
  let(:original) { company.vehicles.find_by(catalog_source_id: source.id, catalog_source_key: '1') }

  before { Catalog::IngestionService.new(company: company, source: source).call([FakeCatalogAdapter.home('1')]) }

  def edit(vehicle, attrs) = patch("/api/v1/vehicles/#{vehicle.id}", params: { vehicle: attrs }.to_json, headers: headers)
  def listed(**params)
    get '/api/v1/vehicles', params: params, headers: headers.except('Content-Type')
    body = JSON.parse(response.body)
    (body['vehicles'] || body['items'] || body['data']).map { |v| v['id'].to_s }
  end

  it 'lists only the copy after a field edit, and it stays to order' do
    edit(original, { sale_price: 150_000 })
    expect(response).to have_http_status(:created)
    copy = JSON.parse(response.body)['vehicle']
    expect(copy['status'].to_s).to match(/available.to.order/i)

    expect(listed(source_filter: 'dealer_preferred')).to contain_exactly(copy['id'].to_s)
    expect(listed(source_filter: 'all')).to contain_exactly(copy['id'].to_s, original.id.to_s)
  end

  it 'keeps photos a dealer adds through the real edit, across a sync' do
    edit(original, { images: mine })
    expect(response).to have_http_status(:ok)
    expect(company.vehicles.count).to eq(1)

    Catalog::IngestionService.new(company: company, source: source).call([FakeCatalogAdapter.home('1')])
    expect(original.reload.images).to eq(mine)
  end

  it 'tells the Champion sync which fields the dealer changed' do
    home = company.vehicles.create!(listing_type: 'manufactured_home', status: 'available_to_order', source: 'champion_ims',
                                    champion_model_id: 'M1', make: 'Champion', model: 'Aspire', year: 2026,
                                    serial_number: 'CHAMP-M1', bedrooms: 3, bathrooms: 2,
                                    images: [{ 'url' => 'https://champion/1.jpg' }], video_url: 'https://champion/v')
    edit(home, { images: mine, video_url: 'https://champion/v' })

    expect(response).to have_http_status(:ok)
    expect(home.reload.dealer_media_fields).to contain_exactly('images', 'photo_url')
  end

  it 'tells the Champion sync when a dealer deletes a photo' do
    home = company.vehicles.create!(listing_type: 'manufactured_home', status: 'available_to_order', source: 'champion_ims',
                                    champion_model_id: 'M2', make: 'Champion', model: 'Aspire', year: 2026,
                                    serial_number: 'CHAMP-M2', bedrooms: 3, bathrooms: 2,
                                    images: ['https://champion/1.jpg', 'https://champion/2.jpg'])
    delete "/api/v1/vehicles/#{home.id}/images", params: { url: 'https://champion/2.jpg' }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(home.reload.images).to eq(['https://champion/1.jpg'])
    expect(home.dealer_media_fields).to contain_exactly('images', 'photo_url')
  end
end
