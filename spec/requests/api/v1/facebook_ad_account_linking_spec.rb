# frozen_string_literal: true

require 'rails_helper'

# Regression: nothing in the codebase ever wrote metadata['ad_account_id'], so
# the ad builder's "No ad account linked" guard could never be satisfied and
# every paid-ad launch failed. These cover discovery, selection and the fact
# that ad-account calls must use the *user* token, not the Page token.
RSpec.describe 'Facebook ad account linking', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:integration) do
    company.facebook_integrations.create!(
      page_id:           '1280160285171602',
      page_name:         'DealerTide',
      page_access_token: 'PAGE-TOKEN',
      user_access_token: 'USER-TOKEN',
      status:            'active',
      is_deleted:        false
    )
  end

  let(:graph_accounts) do
    { 'data' => [
      { 'id' => 'act_111', 'name' => 'DealerTide Ads', 'account_status' => 1, 'currency' => 'USD' },
      { 'id' => 'act_222', 'name' => 'Second Account', 'account_status' => 1, 'currency' => 'USD' }
    ] }
  end

  describe 'GET /api/v1/integrations/facebook/ad_accounts' do
    it 'lists ad accounts with the act_ prefix stripped' do
      allow(MetaGraphApi).to receive(:get_user_ad_accounts).with('USER-TOKEN').and_return(graph_accounts)

      get '/api/v1/integrations/facebook/ad_accounts', headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['ad_accounts'].map { |a| a['id'] }).to eq(%w[111 222])
      expect(body['selected_ad_account_id']).to be_nil
    end

    it 'reports the missing user token instead of calling Graph with a Page token' do
      integration.update!(user_access_token: nil)
      expect(MetaGraphApi).not_to receive(:get_user_ad_accounts)

      get '/api/v1/integrations/facebook/ad_accounts', headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['error']).to match(/Reconnect Facebook/i)
    end
  end

  describe 'POST /api/v1/integrations/facebook/link_ad_account' do
    before do
      allow(MetaGraphApi).to receive(:get_user_ad_accounts).with('USER-TOKEN').and_return(graph_accounts)
    end

    it 'persists the bare numeric id so /act_ paths are not double-prefixed' do
      post '/api/v1/integrations/facebook/link_ad_account',
           params: { ad_account_id: 'act_222' }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      meta = integration.reload.metadata.deep_stringify_keys
      expect(meta['ad_account_id']).to eq('222')
      expect(meta['ad_account_name']).to eq('Second Account')
    end

    it 'rejects an ad account the connection cannot reach' do
      post '/api/v1/integrations/facebook/link_ad_account',
           params: { ad_account_id: '999' }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(integration.reload.metadata.deep_stringify_keys['ad_account_id']).to be_nil
    end

    it 'preserves unrelated metadata such as the Instagram account' do
      integration.update!(metadata: { 'instagram_business_account_id' => 'ig-1' })

      post '/api/v1/integrations/facebook/link_ad_account',
           params: { ad_account_id: '111' }.to_json, headers: headers

      meta = integration.reload.metadata.deep_stringify_keys
      expect(meta['instagram_business_account_id']).to eq('ig-1')
      expect(meta['ad_account_id']).to eq('111')
    end
  end

  describe 'GET /api/v1/integrations/facebook/status' do
    it 'surfaces the linked ad account and ads readiness' do
      integration.update!(metadata: { 'ad_account_id' => '111', 'ad_account_name' => 'DealerTide Ads' })

      get '/api/v1/integrations/facebook/status', headers: headers

      body = JSON.parse(response.body)
      expect(body['ad_account_id']).to eq('111')
      expect(body['ad_account_name']).to eq('DealerTide Ads')
      expect(body['ads_ready']).to be(true)
    end

    it 'is not ads_ready when the connection has no user token' do
      integration.update!(metadata: { 'ad_account_id' => '111' }, user_access_token: nil)

      get '/api/v1/integrations/facebook/status', headers: headers

      expect(JSON.parse(response.body)['ads_ready']).to be(false)
    end
  end

  describe 'POST /api/v1/ad-campaigns/launch' do
    let(:launch_params) do
      { primary_text: 'Hello', headline: 'One Platform', link_url: 'https://app.dealertide.com/f/abc',
        daily_budget: 9, duration_days: 3 }
    end

    it 'still refuses to launch when no ad account is linked' do
      post '/api/v1/ad-campaigns/launch', params: launch_params.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/No ad account linked/)
    end

    it 'drives the Meta ad endpoints with the user token, not the Page token' do
      integration.update!(metadata: { 'ad_account_id' => '111' })

      expect(MetaGraphApi).to receive(:create_campaign)
        .with('111', 'USER-TOKEN', hash_including(objective: 'OUTCOME_LEADS'))
        .and_return({ 'id' => 'c1' })
      allow(MetaGraphApi).to receive(:create_ad_set).and_return({ 'id' => 'as1' })
      allow(MetaGraphApi).to receive(:create_ad_creative).and_return({ 'id' => 'cr1' })
      allow(MetaGraphApi).to receive(:create_ad).and_return({ 'id' => 'ad1' })
      allow(MetaGraphApi).to receive(:update_campaign_status).and_return({})

      post '/api/v1/ad-campaigns/launch', params: launch_params.to_json, headers: headers

      expect(response).to have_http_status(:created)
    end

    it 'asks the user to reconnect when the connection predates user-token capture' do
      integration.update!(metadata: { 'ad_account_id' => '111' }, user_access_token: nil)
      expect(MetaGraphApi).not_to receive(:create_campaign)

      post '/api/v1/ad-campaigns/launch', params: launch_params.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/Reconnect Facebook/i)
    end
  end
end
