# frozen_string_literal: true

require 'rails_helper'

# The settings screen sends social_media_settings. The controller required
# settings, so every save from the screen answered 400 and nothing was stored.
RSpec.describe 'Api::V1::SocialMediaSettings update', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  it 'saves what the settings screen sends' do
    patch '/api/v1/social-media-settings',
          params: { social_media_settings: { comment_sync_enabled: false, push_on_comments: false } }.to_json,
          headers: headers

    expect(response).to have_http_status(:ok)
    stored = SocialMediaSettingsService.for_company(company)
    stored = stored[:settings] || stored['settings'] || stored
    expect(stored.to_h.stringify_keys).to include('comment_sync_enabled' => false, 'push_on_comments' => false)
  end

  it 'still takes the older settings key' do
    patch '/api/v1/social-media-settings', params: { settings: { push_on_comments: false } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
  end
end
