# frozen_string_literal: true

require 'rails_helper'

# The dealership's own Like on its own Page content, via
# pages_manage_engagement. The page access token makes the Page the actor, so
# no personal account is involved.
RSpec.describe 'Api::V1::BrandHealth page likes', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:integration) do
    company.facebook_integrations.create!(
      page_id: '55501', page_name: 'Test Page',
      page_access_token: 'page-token', status: 'active'
    )
  end

  describe 'POST /api/v1/brand-health/posts/:post_id/like' do
    it 'likes the post as the page' do
      expect(MetaGraphApi).to receive(:like_object)
        .with('55501_900', 'page-token').and_return({ 'success' => true })

      post '/api/v1/brand-health/posts/55501_900/like', headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['has_liked']).to be true
    end

    # The page token can like anything the page can reach, so without this the
    # caller could put the dealership's name on a post that is not theirs.
    it 'refuses an object that is not on this page' do
      expect(MetaGraphApi).not_to receive(:like_object)

      post '/api/v1/brand-health/posts/99999_900/like', headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)['error']).to match(/does not belong/)
    end

    it 'reports a page that is not connected' do
      integration.update!(status: 'expired')

      post '/api/v1/brand-health/posts/55501_900/like', headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/No Facebook page connected/)
    end

    it 'marks the integration expired when Meta rejects the token' do
      allow(MetaGraphApi).to receive(:like_object)
        .and_raise(MetaGraphApi::ExpiredTokenError.new('token expired'))

      post '/api/v1/brand-health/posts/55501_900/like', headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(integration.reload.status).to eq('expired')
    end

    it 'surfaces a Meta refusal rather than claiming success' do
      allow(MetaGraphApi).to receive(:like_object)
        .and_raise(MetaGraphApi::Error.new('(#200) Permissions error'))

      post '/api/v1/brand-health/posts/55501_900/like', headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/Permissions error/)
    end
  end

  describe 'DELETE /api/v1/brand-health/posts/:post_id/like' do
    it 'removes the page like' do
      expect(MetaGraphApi).to receive(:unlike_object)
        .with('55501_900', 'page-token').and_return({ 'success' => true })

      delete '/api/v1/brand-health/posts/55501_900/like', headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['has_liked']).to be false
    end

    it 'refuses an object that is not on this page' do
      expect(MetaGraphApi).not_to receive(:unlike_object)

      delete '/api/v1/brand-health/posts/99999_900/like', headers: headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
