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
  # Meta requires a link and an image on every item, so a home without both is
  # deliberately held back. This one is complete.
  let!(:intake_form) do
    company.intake_forms.create!(name: 'Get Info', is_active: true, schema: {})
  end

  let!(:home) do
    company.vehicles.create!(
      year: 2024, make: 'Clayton', model: 'Ridgeview',
      vin: "VIN#{SecureRandom.hex(6).upcase}",
      photo_url: 'https://example.com/ridgeview.jpg',
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

  # Meta rejects a whole item for one empty required field and reports it back
  # in the feed's issue log. Sending a row we already know is incomplete only
  # produces an error report, so it is held back and surfaced in settings.
  describe 'incomplete homes' do
    it 'leaves out a home with no price' do
      company.vehicles.create!(
        year: 2026, make: 'Fairmont', model: 'Asdfds',
        vin: "VIN#{SecureRandom.hex(6).upcase}",
        photo_url: 'https://example.com/fairmont.jpg',
        status: 'available', sale_price: nil, is_deleted: false
      )

      feed_get

      ids = CSV.parse(response.body, headers: true).map { |r| r['id'] }
      expect(ids).to eq(["unit-#{home.id}"])
    end

    it 'leaves out a home with no image' do
      no_image = company.vehicles.create!(
        year: 2026, make: 'Skyline', model: 'Prairie Dune',
        vin: "VIN#{SecureRandom.hex(6).upcase}",
        status: 'available', sale_price: 90_000, is_deleted: false
      )

      feed_get

      ids = CSV.parse(response.body, headers: true).map { |r| r['id'] }
      expect(ids).not_to include("unit-#{no_image.id}")
    end

    # An empty string is truthy in Ruby, so `condition || 'new'` left it blank
    # and Meta rejected the item for a missing required value.
    it 'falls back to new when condition is an empty string' do
      home.update_column(:condition, '')

      feed_get

      row = CSV.parse(response.body, headers: true).find { |r| r['id'] == "unit-#{home.id}" }
      expect(row['condition']).to eq('new')
    end
  end

  # A dealer should know a status will send nothing before ticking it, not
  # after Meta bounces the items. Available to Order homes rarely have a price.
  describe 'GET /api/v1/meta/catalog/info' do
    let(:user) do
      User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                   password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
    end
    let(:auth) do
      { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
        'Content-Type' => 'application/json' }
    end

    let!(:no_price) do
      company.vehicles.create!(
        year: 2026, make: 'Fairmont', model: 'Asdfds',
        vin: "VIN#{SecureRandom.hex(6).upcase}",
        photo_url: 'https://example.com/f.jpg',
        status: 'available_to_order', sale_price: nil, is_deleted: false
      )
    end

    it 'counts what cannot be sent against the status it belongs to' do
      get '/api/v1/meta/catalog/info', headers: auth

      catalog = JSON.parse(response.body)['catalog']
      expect(catalog['excluded_by_status']['available_to_order']).to eq(1)
      expect(catalog['eligible_by_status']['available_to_order'].to_i).to eq(0)
    end

    # Counted across every status, not just the selected ones, or the warning
    # only appears once the damage is done.
    it 'counts a status the dealer has not selected' do
      get '/api/v1/meta/catalog/info', headers: auth

      catalog = JSON.parse(response.body)['catalog']
      expect(catalog['statuses']).not_to include('available_to_order')
      expect(catalog['excluded_by_status']['available_to_order']).to eq(1)
    end

    it 'counts only selected statuses as active' do
      get '/api/v1/meta/catalog/info', headers: auth

      expect(JSON.parse(response.body)['catalog']['active_count']).to eq(1)
    end

    it 'lists held-back homes only for the selected statuses' do
      get '/api/v1/meta/catalog/info', headers: auth

      ids = JSON.parse(response.body)['catalog']['excluded'].map { |e| e['id'] }
      expect(ids).not_to include("unit-#{no_price.id}")
    end

    # The feed can look perfectly healthy while every ad click 403s, because
    # homes are only viewable publicly while this flag is on. Surfacing it in
    # settings beats discovering it from a shopper hitting an error.
    it 'reports whether public inventory is switched on' do
      get '/api/v1/meta/catalog/info', headers: auth

      expect(JSON.parse(response.body)['catalog']).to have_key('public_inventory_enabled')
    end

    it 'reports it as off when the company has it disabled' do
      company.update!(public_inventory_enabled: false)

      get '/api/v1/meta/catalog/info', headers: auth

      expect(JSON.parse(response.body)['catalog']['public_inventory_enabled']).to be false
    end
  end

  # Every home used to point at the same bare enquiry form, so a shopper who
  # clicked a specific home landed somewhere that never mentioned it.
  describe 'where an ad click lands' do
    before { company.update!(public_inventory_enabled: true, public_inventory_token: 'inv-token') }

    def link_for(id = home.id)
      feed_get
      CSV.parse(response.body, headers: true).find { |r| r['id'] == "unit-#{id}" }&.fetch('link')
    end

    it 'points at the home its own public page' do
      expect(link_for).to include("/public/inventory/#{home.id}")
    end

    it 'carries what that page needs to load' do
      link = link_for
      expect(link).to include('token=inv-token')
      expect(link).to include("company_id=#{company.id}")
    end

    it 'attaches a lead form so the page shows it inline' do
      expect(link_for).to match(/lead_form_id=\d+/)
    end

    it 'keeps the campaign UTMs, so attribution is unaffected' do
      link = link_for
      expect(link).to include('utm_source=facebook')
      expect(link).to include('utm_medium=catalog_ad')
    end

    # The page answers 403 with public inventory off, so the click would be
    # wasted. Better a generic form than an error.
    it 'falls back to the enquiry form when public inventory is off' do
      company.update!(public_inventory_enabled: false)

      link = link_for
      expect(link).not_to include('/public/inventory/')
      expect(link).to include('/f/')
    end

    it 'falls back when the company has no inventory token' do
      company.update!(public_inventory_token: nil)

      expect(link_for).not_to include('/public/inventory/')
    end
  end

  # custom_label_3 read location_city, which is populated on almost no home, so
  # the label was empty and a per-location product set had nothing to filter on.
  describe 'the location label' do
    it 'carries the rooftop name so a product set can filter by it' do
      location = company.locations.create!(name: 'Aurora Sales Center',
                                           code: "AUR-#{SecureRandom.hex(2)}", active: true)
      home.update!(location_id: location.id)

      feed_get

      row = CSV.parse(response.body, headers: true).find { |r| r['id'] == "unit-#{home.id}" }
      expect(row['custom_label_3']).to eq('aurora_sales_center')
    end

    it 'is left empty for a home with no rooftop' do
      home.update!(location_id: nil)

      feed_get

      row = CSV.parse(response.body, headers: true).find { |r| r['id'] == "unit-#{home.id}" }
      expect(row['custom_label_3'].to_s).to eq('')
    end
  end
end
