# frozen_string_literal: true

require 'rails_helper'

# The app has to pick a location for a user who has not chosen one, or it blocks
# the whole UI behind a "Select a Location" gate. `is_default` and `is_corporate`
# are the only record of which one that should be, and neither was serialized —
# so the selector had nothing to go on and every multi-rooftop company was gated
# on every fresh session.
RSpec.describe 'Api::V1::Locations default flags', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'T', last_name: 'U',
      password: 'Pass1234!', company_id: company.id,
      role: 'platform_admin'
    )
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  # A new company is seeded with a default location and a corporate one, and a
  # DB constraint allows only one corporate location per company — so the flags
  # under test are already set for us.
  let(:default_loc)   { company.locations.find_by(is_default: true) }
  let(:corporate_loc) { company.locations.find_by(is_corporate: true) }

  # A third rooftop, so this is a genuinely multi-location company — the case
  # that has no single-location shortcut and therefore needs the flags.
  let!(:extra_loc) do
    Location.create!(company_id: company.id, name: 'Aurora Sales Center',
                     code: "AUR-#{SecureRandom.hex(2)}", active: true)
  end

  it 'exposes is_default and is_corporate on the locations list' do
    get '/api/v1/locations', headers: headers

    expect(response).to have_http_status(:ok)
    locations = JSON.parse(response.body)['locations']
    expect(locations.length).to be >= 3

    by_id = locations.index_by { |l| l['id'] }

    expect(by_id[default_loc.id]['is_default']).to be true
    expect(by_id[corporate_loc.id]['is_corporate']).to be true
    expect(by_id[extra_loc.id]['is_default']).to be false
    expect(by_id[extra_loc.id]['is_corporate']).to be false
  end

  it 'names exactly one default location, so the selector has one answer' do
    get '/api/v1/locations', headers: headers

    locations = JSON.parse(response.body)['locations']
    expect(locations.count { |l| l['is_default'] }).to eq(1)
  end

  it 'exposes them on a single location too' do
    get "/api/v1/locations/#{default_loc.id}", headers: headers

    expect(response).to have_http_status(:ok)
    location = JSON.parse(response.body)['location']
    expect(location['is_default']).to be true
    expect(location['is_corporate']).to be false
  end
end
