# frozen_string_literal: true

require 'rails_helper'
require 'csv'

# Commerce Manager takes CSV, TSV, XML (RSS/ATOM) or XLSX, and validates the
# URL before it ever fetches. The feed used to serve JSON, so adding it as a
# data source failed with "URL does not link to supported file".
RSpec.describe 'Api::V1::MetaCatalog feed', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing')
  end
  let!(:home) do
    company.vehicles.create!(
      year: 2024, make: 'Clayton', model: 'Ridgeview',
      vin: "VIN#{SecureRandom.hex(6).upcase}",
      status: 'available', sale_price: 129_900, is_deleted: false
    )
  end

  before do
    company.update!(meta_catalog_token: 'feed-token') if company.meta_catalog_token.blank?
  end

  def feed_get(suffix = '.csv', params = { token: 'feed-token' })
    get "/api/v1/meta/catalog/#{company.id}/feed#{suffix}", params: params
  end

  it 'serves CSV by default, which is what Meta can read' do
    feed_get

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('text/csv')
  end

  it 'leads with Meta\'s column headers' do
    feed_get

    header = CSV.parse(response.body).first
    expect(header.first(8)).to eq(
      %w[id title description availability condition price link image_link]
    )
  end

  it 'emits one row per home, with the values Meta expects' do
    feed_get

    rows = CSV.parse(response.body, headers: true)
    expect(rows.length).to eq(1)
    row = rows.first
    expect(row['id']).to eq("unit-#{home.id}")
    expect(row['availability']).to eq('in stock')
    expect(row['price']).to eq('129900.00 USD')
  end

  it 'keeps a dash out of the product title, which shows in the dealer ads' do
    feed_get

    title = CSV.parse(response.body, headers: true).first['title']
    expect(title).not_to include('—')
    expect(title).not_to include('–')
  end

  it 'still serves JSON when asked, for our own preview' do
    feed_get('.json')

    expect(response.media_type).to eq('application/json')
    expect(JSON.parse(response.body).first['id']).to eq("unit-#{home.id}")
  end

  it 'refuses a request with no token' do
    get "/api/v1/meta/catalog/#{company.id}/feed.csv"

    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses a request with the wrong token' do
    feed_get('.csv', { token: 'nope' })

    expect(response).to have_http_status(:unauthorized)
  end
end
