# frozen_string_literal: true

require 'rails_helper'

# The public inventory token is in every public home link, so it is not a
# secret. Anyone holding one used to be able to pass statuses=sold,pending and
# list homes the dealer never published. A request may now only see statuses
# the dealer has put on show: the company public statuses, homes for sale, a
# status ticked on one of their website blocks, or one in their saved embed.
RSpec.describe 'Public inventory statuses allowlist', type: :request do
  let(:company) do
    create(:company).tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true,
                                             'public_statuses' => %w[available] })
    end
  end

  def home(status)
    Vehicle.create!(company: company, year: 2026, make: 'Kabco', model: 'Rubicon',
                    listing_type: 'manufactured_home', vin: "VIN#{SecureRandom.hex(6).upcase}",
                    status: status, is_deleted: false, condition: 'new', bedrooms: 3, bathrooms: 2,
                    serial_number: "SN#{SecureRandom.hex(5).upcase}")
  end

  let!(:available) { home('available') }
  let!(:to_order)  { home('available_to_order') }
  let!(:sold)      { home('sold') }
  let!(:pending)   { home('pending') }

  def ids(statuses, path = '/public/inventory')
    get path, params: { token: company.public_inventory_token, statuses: statuses }
    JSON.parse(response.body)['items'].map { |i| i['id'] }
  end

  def website_with_block(statuses)
    location = company.locations.create!(name: 'Lot')
    site = company.websites.create!(location_id: location.id, name: 'Site', slug: "s-#{SecureRandom.hex(4)}")
    site.website_pages.create!(title: 'Sold', blocks: [
      { 'type' => 'section', 'content' => { 'columns' => [
        { 'type' => 'inventory', 'content' => { 'statuses' => statuses } }
      ] } }
    ])
  end

  it 'drops a status the dealer never published instead of erroring' do
    expect(ids('available,sold,pending')).to eq([available.id])
    expect(response).to have_http_status(:ok)
  end

  it 'shows nothing when every requested status is unpublished' do
    expect(ids('sold')).to eq([])
  end

  it 'always allows homes for sale, even when public statuses list only one' do
    expect(ids('available,available_to_order')).to match_array([available.id, to_order.id])
  end

  it 'falls back to the company public statuses when none are passed' do
    get '/public/inventory', params: { token: company.public_inventory_token }
    expect(JSON.parse(response.body)['items'].map { |i| i['id'] }).to eq([available.id])
  end

  it 'allows a status ticked on a block of one of the dealer website pages, at any depth' do
    website_with_block(%w[sold])
    expect(ids('sold,pending')).to eq([sold.id])
  end

  it 'ignores blocks on a deleted website' do
    website_with_block(%w[sold]).website.update!(is_deleted: true)
    expect(ids('sold')).to eq([])
  end

  it 'allows a status in the saved embed configuration, stored as a string or a list' do
    Setting.set('Company', company.id, 'embed_inventory_config', { 'statuses' => 'pending' })
    expect(ids('pending,sold')).to eq([pending.id])
  end

  it 'ignores another company publishing the status' do
    other = create(:company)
    loc = other.locations.create!(name: 'Elsewhere')
    other.websites.create!(location_id: loc.id, name: 'O', slug: "o-#{SecureRandom.hex(4)}")
         .website_pages.create!(title: 'Sold', blocks: [{ 'type' => 'inventory', 'content' => { 'statuses' => %w[sold] } }])
    expect(ids('sold')).to eq([])
  end

  it 'applies the same limit to filters, featured and a single home' do
    get '/public/inventory/featured', params: { token: company.public_inventory_token, statuses: 'sold' }
    expect(JSON.parse(response.body)['items']).to eq([])

    get '/public/inventory/filters', params: { token: company.public_inventory_token, statuses: 'sold' }
    expect(response).to have_http_status(:ok)

    get "/public/inventory/#{sold.id}", params: { token: company.public_inventory_token, statuses: 'sold' }
    expect(response).to have_http_status(:forbidden)

    website_with_block(%w[sold])
    get "/public/inventory/#{sold.id}", params: { token: company.public_inventory_token, statuses: 'sold' }
    expect(response).to have_http_status(:ok)
  end
end
