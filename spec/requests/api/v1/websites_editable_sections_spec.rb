# frozen_string_literal: true

require 'rails_helper'

# The websites list offers "Event Calendar" and "Lot Rent" only on sites that
# have those sections, so it has to say which sites do.
RSpec.describe 'Api::V1::Websites editable sections', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'Denver') }

  def site(name)
    company.websites.create!(location_id: location.id, name: name, slug: "s-#{SecureRandom.hex(4)}")
  end

  def headers
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                        password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  let(:events_block) { { 'id' => 'b1', 'type' => 'features', 'order' => 0, 'content' => { 'layout' => 'events', 'features' => [] } } }
  let(:pricing_block) { { 'id' => 'b2', 'type' => 'pricing', 'order' => 1, 'content' => { 'plans' => [] } } }
  let(:cards_block) { { 'id' => 'b3', 'type' => 'features', 'order' => 0, 'content' => { 'layout' => 'cards' } } }

  it 'names the sections each site has' do
    park = site('Park')
    park.website_pages.create!(title: 'Events', path: '/events', blocks: [events_block])
    park.website_pages.create!(title: 'Sites', path: '/homesites', blocks: [pricing_block])
    dealer = site('Dealer')
    dealer.website_pages.create!(title: 'Home', path: '/', blocks: [cards_block])

    expect(Website.editable_sections_for([park.id, dealer.id])).to eq(park.id => %w[events lot_rent], dealer.id => [])

    get '/api/v1/websites', headers: headers
    expect(response).to have_http_status(:ok)
    items = JSON.parse(response.body)['items'].index_by { |i| i['id'] }
    expect(items[park.id]['editable_sections']).to match_array(%w[events lot_rent])
    expect(items[dealer.id]['editable_sections']).to eq([])
  end

  it 'ignores deleted pages' do
    park = site('Park')
    park.website_pages.create!(title: 'Old', path: '/old', blocks: [pricing_block], is_deleted: true)

    expect(Website.editable_sections_for([park.id])).to eq({})
  end
end
