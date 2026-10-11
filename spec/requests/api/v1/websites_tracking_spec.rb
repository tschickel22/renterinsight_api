# frozen_string_literal: true

require 'rails_helper'

# Every tracking id the live site can write a snippet for has to survive the
# save: a field the controller doesn't permit is dropped without a word, and
# the dealer is left with a pixel that never fires.
RSpec.describe 'Api::V1::Websites tracking', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'Brooksville') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:auth_headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end
  let(:website) { company.websites.create!(location_id: location.id, name: 'EHS', slug: "s-#{SecureRandom.hex(4)}") }

  it 'keeps every tracking id the site can fire' do
    ids = {
      google_ads_id: 'AW-17782600637', tiktok_pixel_id: 'C4ABCDEFGHIJKLMNOPQR', microsoft_clarity_id: 'k8x2abcd9z',
      logrocket_app_id: 'abc123/easy-homesource', hotjar_id: '1234567'
    }
    patch "/api/v1/websites/#{website.id}", params: { website: { tracking_config: ids } }.to_json, headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(website.reload.tracking_config.symbolize_keys).to include(ids)
    expect(Websites::TrackingTags::FIELDS).to include(*ids.keys.map(&:to_s))
  end
end
