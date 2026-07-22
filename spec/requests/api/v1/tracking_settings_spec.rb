# frozen_string_literal: true

require 'rails_helper'

# Covers the tracking-settings update path. The failure mode this catches:
# a legacy Location row that trips one of Location's unrelated validators
# (an imported country: "USA" > max 2 chars, a long zip, etc.) used to
# raise RecordInvalid mid-loop and leave the company default + earlier
# locations partially committed. The controller now bypasses AR validations
# on the JSONB blob save AND wraps the whole thing in a transaction.
RSpec.describe 'Api::V1 TrackingSettings', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:loc_a)   { Location.create!(company_id: company.id, name: 'A', code: 'A', active: true) }
  let(:loc_b)   { Location.create!(company_id: company.id, name: 'B', code: 'B', active: true) }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@x.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: admin.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  it 'saves company default + per-location tracking in one round trip' do
    put '/api/v1/company/tracking-settings',
        params: {
          company: { metaPixelId: '111' },
          locations: [
            { id: loc_a.id, tracking: { metaPixelId: '222' } },
            { id: loc_b.id, tracking: { metaPixelId: '333' } }
          ]
        }.to_json,
        headers: headers

    expect(response).to have_http_status(:ok)
    expect(company.reload.tracking_settings).to eq('metaPixelId' => '111')
    expect(loc_a.reload.tracking_settings).to eq('metaPixelId' => '222')
    expect(loc_b.reload.tracking_settings).to eq('metaPixelId' => '333')
  end

  it 'saves through even when a location has legacy validator debt (country: USA)' do
    # Sneak past validators to reproduce the "legacy import" state the
    # controller used to blow up on.
    loc_b.update_column(:country, 'USA') # length > 2 → would trip validator on update!
    expect(loc_b.reload.valid?).to eq(false) # confirm the landmine is armed

    put '/api/v1/company/tracking-settings',
        params: {
          company: { metaPixelId: '111' },
          locations: [
            { id: loc_a.id, tracking: { metaPixelId: '222' } },
            { id: loc_b.id, tracking: { metaPixelId: '333' } }
          ]
        }.to_json,
        headers: headers

    expect(response).to have_http_status(:ok)
    expect(company.reload.tracking_settings).to eq('metaPixelId' => '111')
    expect(loc_a.reload.tracking_settings).to eq('metaPixelId' => '222')
    expect(loc_b.reload.tracking_settings).to eq('metaPixelId' => '333')
  end

  it 'sanitizes unknown keys away instead of persisting them' do
    put '/api/v1/company/tracking-settings',
        params: { company: { metaPixelId: '111', sneakyKey: 'nope' }, locations: [] }.to_json,
        headers: headers

    expect(response).to have_http_status(:ok)
    expect(company.reload.tracking_settings).to eq('metaPixelId' => '111')
  end

  it 'silently skips location ids that do not belong to this company' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'rv')
    foreign_loc = Location.create!(company_id: other.id, name: 'X', code: 'X', active: true)

    put '/api/v1/company/tracking-settings',
        params: { locations: [{ id: foreign_loc.id, tracking: { metaPixelId: 'x' } }] }.to_json,
        headers: headers

    expect(response).to have_http_status(:ok)
    expect(foreign_loc.reload.tracking_settings).to eq({})
  end
end
