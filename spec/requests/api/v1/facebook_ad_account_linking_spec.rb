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

  # Meta refused ad-creative calls with "(#200) Requires pages_manage_ads
  # permission to manage the object" — the scope was simply never requested.
  describe 'OAuth scopes' do
    it 'requests every permission the ads flow depends on' do
      expect(Api::V1::Integrations::FacebookController::SCOPES)
        .to include('pages_manage_ads', 'ads_management', 'ads_read', 'leads_retrieval')
    end
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

    # Meta lets an ad account be named after its owner, or left unnamed so it
    # renders as a bare id. With several accounts on one login that's
    # unidentifiable, so lead the label with the business portfolio.
    it 'labels accounts by their owning business portfolio' do
      allow(MetaGraphApi).to receive(:get_user_ad_accounts).and_return(
        { 'data' => [
          { 'id' => 'act_47496870', 'name' => '47496870', 'currency' => 'USD',
            'business' => { 'id' => '9', 'name' => 'Renter Insight' } },
          { 'id' => 'act_2057705311311123', 'name' => 'Tom Schickel', 'currency' => 'USD' }
        ] }
      )

      get '/api/v1/integrations/facebook/ad_accounts', headers: headers

      labels = JSON.parse(response.body)['ad_accounts'].map { |a| a['label'] }
      expect(labels).to eq([
        'Renter Insight · 47496870 · act_47496870',
        'Tom Schickel · act_2057705311311123'
      ])
    end

    it 'falls back to the id when an account has neither name nor portfolio' do
      allow(MetaGraphApi).to receive(:get_user_ad_accounts).and_return(
        { 'data' => [{ 'id' => 'act_555', 'currency' => 'USD' }] }
      )

      get '/api/v1/integrations/facebook/ad_accounts', headers: headers

      expect(JSON.parse(response.body)['ad_accounts'].first['label']).to eq('act_555')
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
      expect(meta['ad_account_name']).to eq('Second Account · act_222')
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

    def stub_successful_launch
      allow(MetaGraphApi).to receive(:create_campaign).and_return({ 'id' => 'c1' })
      allow(MetaGraphApi).to receive(:create_ad_set).and_return({ 'id' => 'as1' })
      allow(MetaGraphApi).to receive(:create_ad_creative).and_return({ 'id' => 'cr1' })
      allow(MetaGraphApi).to receive(:create_ad).and_return({ 'id' => 'ad1' })
      allow(MetaGraphApi).to receive(:update_campaign_status).and_return({})
    end

    it 'drives the Meta ad endpoints with the user token, not the Page token' do
      integration.update!(metadata: { 'ad_account_id' => '111' })
      stub_successful_launch

      expect(MetaGraphApi).to receive(:create_campaign)
        .with('111', 'USER-TOKEN', hash_including(objective: 'OUTCOME_TRAFFIC'))
        .and_return({ 'id' => 'c1' })

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

  # Regression: the wizard sent legacy objectives (LEAD_GENERATION, LINK_CLICKS,
  # REACH). Meta rejects those on new campaigns with "(#100) Objective is
  # invalid" — while listing the legacy names among the valid ones, which makes
  # the error read like a contradiction.
  describe 'objective normalisation on launch' do
    let(:base_params) do
      { primary_text: 'Hello', headline: 'One Platform', link_url: 'https://app.dealertide.com/f/abc',
        daily_budget: 9, duration_days: 3 }
    end

    before do
      integration.update!(metadata: { 'ad_account_id' => '111' })
      allow(MetaGraphApi).to receive(:create_ad_set).and_return({ 'id' => 'as1' })
      allow(MetaGraphApi).to receive(:create_ad_creative).and_return({ 'id' => 'cr1' })
      allow(MetaGraphApi).to receive(:create_ad).and_return({ 'id' => 'ad1' })
      allow(MetaGraphApi).to receive(:update_campaign_status).and_return({})
    end

    def launch_with(extra)
      allow(MetaGraphApi).to receive(:create_campaign).and_return({ 'id' => 'c1' })
      post '/api/v1/ad-campaigns/launch', params: base_params.merge(extra).to_json, headers: headers
    end

    it 'maps legacy REACH to OUTCOME_AWARENESS' do
      launch_with(objective: 'REACH')

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(objective: 'OUTCOME_AWARENESS'))
    end

    it 'maps legacy LINK_CLICKS to OUTCOME_TRAFFIC' do
      launch_with(objective: 'LINK_CLICKS')

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(objective: 'OUTCOME_TRAFFIC'))
    end

    it 'accepts the lowercase recommended_objective the AI settings return' do
      launch_with(objective: 'lead_generation', lead_form_id: '999')

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(objective: 'OUTCOME_LEADS'))
    end

    # Meta's call_to_action types are upper-case constants; the wizard's option
    # values were lower-case, which Meta rejected with a 200-item list.
    it 'upcases a lower-case call to action' do
      launch_with(cta_type: 'learn_more')

      expect(MetaGraphApi).to have_received(:create_ad_creative)
        .with('111', anything, hash_including(call_to_action_type: 'LEARN_MORE'))
    end

    it 'keeps a valid upper-case call to action' do
      launch_with(cta_type: 'GET_QUOTE')

      expect(MetaGraphApi).to have_received(:create_ad_creative)
        .with('111', anything, hash_including(call_to_action_type: 'GET_QUOTE'))
    end

    it 'falls back to LEARN_MORE for a call to action Meta would reject' do
      launch_with(cta_type: 'DO_A_BARREL_ROLL')

      expect(MetaGraphApi).to have_received(:create_ad_creative)
        .with('111', anything, hash_including(call_to_action_type: 'LEARN_MORE'))
    end

    # The wizard quotes "Total Spend" off duration, so an ad set with no stop
    # date would keep billing the daily budget well past what the user agreed to.
    it 'stops the ad set after the chosen duration' do
      travel_to Time.utc(2026, 7, 28, 12, 0, 0) do
        launch_with(duration_days: 3)

        expect(MetaGraphApi).to have_received(:create_ad_set).with(
          '111', anything,
          hash_including(end_time: Time.utc(2026, 7, 31, 12, 0, 0).iso8601)
        )
      end
    end

    # Meta needs its own interest ids; name-only entries fail the whole ad set.
    it 'runs broad rather than sending unresolved interest names' do
      launch_with(interests: ['manufactured housing', 'first time buyers'])

      expect(MetaGraphApi).to have_received(:create_ad_set) do |_acct, _token, **kwargs|
        expect(kwargs[:targeting]).not_to have_key(:flexible_spec)
      end
      expect(JSON.parse(response.body)['notes'].join(' ')).to match(/Interests were not applied/)
    end

    it 'forces SIGN_UP when a native lead form is attached' do
      launch_with(cta_type: 'shop_now', lead_form_id: '999')

      expect(MetaGraphApi).to have_received(:create_ad_creative)
        .with('111', anything, hash_including(call_to_action_type: 'SIGN_UP'))
    end

    it 'falls back to OUTCOME_LEADS for an unrecognised objective' do
      launch_with(objective: 'NOT_A_REAL_OBJECTIVE', lead_form_id: '999')

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(objective: 'OUTCOME_LEADS'))
    end

    # Leads optimisation needs a form or a pixel; with only a website link Meta
    # rejects the ad set, so the campaign has to run as traffic instead.
    it 'downgrades leads to traffic when there is no native lead form' do
      launch_with(objective: 'OUTCOME_LEADS')

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(objective: 'OUTCOME_TRAFFIC'))
      expect(MetaGraphApi).to have_received(:create_ad_set)
        .with('111', anything, hash_including(optimization_goal: 'LINK_CLICKS', promoted_object: nil))
    end

    it 'keeps leads optimisation and promotes the page when a lead form is attached' do
      launch_with(objective: 'OUTCOME_LEADS', lead_form_id: '999')

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(objective: 'OUTCOME_LEADS'))
      expect(MetaGraphApi).to have_received(:create_ad_set).with(
        '111', anything,
        hash_including(optimization_goal: 'LEAD_GENERATION',
                       promoted_object: { page_id: integration.page_id })
      )
    end
  end

  # HOUSING used to be hardcoded on every launch. It cripples targeting when it
  # doesn't apply (software, RV, storage) and is a fair-housing requirement when
  # it does — so it's the user's choice, defaulted from the tenant's industry.
  describe 'special ad categories on launch' do
    let(:base_params) do
      { primary_text: 'Hello', headline: 'One Platform', link_url: 'https://app.dealertide.com/f/abc',
        daily_budget: 9, duration_days: 3 }
    end

    before do
      integration.update!(metadata: { 'ad_account_id' => '111' })
      allow(MetaGraphApi).to receive(:create_campaign).and_return({ 'id' => 'c1' })
      allow(MetaGraphApi).to receive(:create_ad_set).and_return({ 'id' => 'as1' })
      allow(MetaGraphApi).to receive(:create_ad_creative).and_return({ 'id' => 'cr1' })
      allow(MetaGraphApi).to receive(:create_ad).and_return({ 'id' => 'ad1' })
      allow(MetaGraphApi).to receive(:update_campaign_status).and_return({})
    end

    def launch_with(extra)
      post '/api/v1/ad-campaigns/launch', params: base_params.merge(extra).to_json, headers: headers
    end

    it 'sends the category the user picked' do
      launch_with(special_ad_categories: ['HOUSING'])

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(special_ad_categories: ['HOUSING']))
    end

    it 'sends no category when the user selects None' do
      launch_with(special_ad_categories: ['NONE'])

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(special_ad_categories: []))
    end

    it 'accepts a bare string as well as an array' do
      launch_with(special_ad_categories: 'employment')

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(special_ad_categories: ['EMPLOYMENT']))
    end

    it 'drops an unknown category rather than letting Meta reject the campaign' do
      launch_with(special_ad_categories: %w[HOUSING NOT_A_CATEGORY])

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(special_ad_categories: ['HOUSING']))
    end

    it 'falls back to the industry suggestion when the client sends nothing' do
      company.update!(industry: 'manufactured_housing')
      launch_with({})

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(special_ad_categories: ['HOUSING']))
    end

    it 'suggests no category for a software tenant' do
      company.update!(industry: 'saas')
      launch_with({})

      expect(MetaGraphApi).to have_received(:create_campaign)
        .with('111', anything, hash_including(special_ad_categories: []))
    end

    it 'records Ad Builder campaigns as ours' do
      launch_with(special_ad_categories: ['NONE'])

      expect(@company_campaign = AdCampaign.find_by(external_campaign_id: 'c1').created_via).to eq('dealertide')
    end
  end

  describe 'GET /api/v1/ad-campaigns/ad-options' do
    it 'offers the category list and the industry-based suggestion' do
      company.update!(industry: 'manufactured_housing')

      get '/api/v1/ad-campaigns/ad-options', headers: headers

      body = JSON.parse(response.body)
      expect(body['suggested_special_ad_category']).to eq('HOUSING')
      expect(body['special_ad_categories'].map { |c| c['value'] }).to include('HOUSING', 'EMPLOYMENT', 'CREDIT')
    end

    it 'suggests nothing for an RV dealer — vehicle sales are ordinary ads' do
      company.update!(industry: 'rv')

      get '/api/v1/ad-campaigns/ad-options', headers: headers

      expect(JSON.parse(response.body)['suggested_special_ad_category']).to be_nil
    end
  end

  describe 'POST /api/v1/ad-campaigns/sync' do
    it 'pulls campaigns created outside the Ad Builder and marks them as Meta-sourced' do
      integration.update!(metadata: { 'ad_account_id' => '111' })
      allow(MetaGraphApi).to receive(:get_ad_campaigns).and_return(
        { 'data' => [{ 'id' => 'ext-1', 'name' => 'MH Housing Lead Form',
                       'objective' => 'OUTCOME_LEADS', 'status' => 'PAUSED' }] }
      )

      post '/api/v1/ad-campaigns/sync', headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['synced']).to eq(1)
      expect(AdCampaign.find_by(external_campaign_id: 'ext-1').created_via).to eq('meta')
    end

    it 'explains itself when no ad account is linked' do
      post '/api/v1/ad-campaigns/sync', headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/No ad account linked/)
    end
  end

  # Regression: with two ad accounts on one Facebook login, switching the linked
  # account in Settings left the previous account's campaigns in the Ads tab —
  # the sync only ever upserts, so nothing retired them. It read as "the toggle
  # isn't working" when the toggle had in fact saved.
  describe 'switching the linked ad account' do
    def link_account(id)
      integration.update!(metadata: { 'ad_account_id' => id })
    end

    before do
      company.ad_campaigns.create!(external_campaign_id: 'old-1', name: 'Renter Insight May 2024',
                                   status: 'PAUSED', spend: 17.25, ad_account_id: 'OLD-ACCT')
      company.ad_campaigns.create!(external_campaign_id: 'new-1', name: 'DealerTide Demo Push',
                                   status: 'ACTIVE', spend: 4.00, ad_account_id: 'NEW-ACCT')
    end

    it 'lists only the campaigns belonging to the linked account' do
      link_account('NEW-ACCT')

      get '/api/v1/ad-campaigns', headers: headers

      names = JSON.parse(response.body)['campaigns'].map { |c| c['name'] }
      expect(names).to eq(['DealerTide Demo Push'])
    end

    it 'follows the toggle back to the other account' do
      link_account('OLD-ACCT')

      get '/api/v1/ad-campaigns', headers: headers

      names = JSON.parse(response.body)['campaigns'].map { |c| c['name'] }
      expect(names).to eq(['Renter Insight May 2024'])
    end

    it 'keeps the ROI tiles on the same account as the list' do
      link_account('NEW-ACCT')

      get '/api/v1/ad-campaigns/roi_summary', headers: headers

      body = JSON.parse(response.body)
      expect(body['total_spend']).to eq(4.0)
      expect(body['campaign_count']).to eq(1)
    end

    it 'stamps the source account when syncing so the next switch is clean' do
      link_account('NEW-ACCT')
      allow(MetaGraphApi).to receive(:get_ad_campaigns).and_return(
        { 'data' => [{ 'id' => 'new-2', 'name' => 'Another DealerTide Ad', 'status' => 'ACTIVE' }] }
      )

      post '/api/v1/ad-campaigns/sync', headers: headers

      expect(AdCampaign.find_by(external_campaign_id: 'new-2').ad_account_id).to eq('NEW-ACCT')
    end

    it 'shows everything when no account is linked rather than hiding the lot' do
      integration.update!(metadata: {})

      get '/api/v1/ad-campaigns', headers: headers

      expect(JSON.parse(response.body)['campaigns'].length).to eq(2)
    end
  end

  # Every ad getting its own campaign and ad set restarts Meta's learning phase
  # and makes the budgets bid against each other. Let a new creative join one.
  describe 'attaching an ad to an existing campaign or ad set' do
    let(:launch_params) do
      { primary_text: 'Hello', headline: 'One Platform', link_url: 'https://app.dealertide.com/f/abc',
        daily_budget: 9, duration_days: 3 }
    end

    before do
      integration.update!(metadata: { 'ad_account_id' => '111' })
      allow(MetaGraphApi).to receive(:create_campaign).and_return({ 'id' => 'new-camp' })
      allow(MetaGraphApi).to receive(:create_ad_set).and_return({ 'id' => 'new-adset' })
      allow(MetaGraphApi).to receive(:create_ad_creative).and_return({ 'id' => 'cr1' })
      allow(MetaGraphApi).to receive(:create_ad).and_return({ 'id' => 'ad1' })
      allow(MetaGraphApi).to receive(:update_campaign_status).and_return({})
      allow(MetaGraphApi).to receive(:delete_campaign).and_return({})
    end

    def launch(extra = {})
      post '/api/v1/ad-campaigns/launch', params: launch_params.merge(extra).to_json, headers: headers
    end

    it 'creates a campaign and ad set when none is chosen' do
      launch

      expect(MetaGraphApi).to have_received(:create_campaign)
      expect(MetaGraphApi).to have_received(:create_ad_set)
    end

    it 'reuses the chosen campaign and only builds a new ad set' do
      launch(meta_campaign_id: 'existing-camp')

      expect(MetaGraphApi).not_to have_received(:create_campaign)
      expect(MetaGraphApi).to have_received(:create_ad_set)
        .with('111', anything, hash_including(campaign_id: 'existing-camp'))
    end

    it 'skips both when an ad set is chosen, adding just the creative' do
      launch(meta_campaign_id: 'existing-camp', meta_adset_id: 'existing-adset')

      expect(MetaGraphApi).not_to have_received(:create_campaign)
      expect(MetaGraphApi).not_to have_received(:create_ad_set)
      expect(MetaGraphApi).to have_received(:create_ad)
        .with('111', anything, hash_including(ad_set_id: 'existing-adset'))
    end

    it 'leaves an existing campaign\'s status alone' do
      launch(meta_campaign_id: 'existing-camp')

      expect(MetaGraphApi).not_to have_received(:update_campaign_status)
    end

    it 'activates a campaign it created itself' do
      launch

      expect(MetaGraphApi).to have_received(:update_campaign_status)
        .with('new-camp', anything, hash_including(status: 'ACTIVE'))
    end

    # Rolling back someone else's campaign would delete their live ads.
    it 'never deletes a campaign it did not create when a later step fails' do
      allow(MetaGraphApi).to receive(:create_ad_creative).and_raise(MetaGraphApi::Error, 'boom')

      launch(meta_campaign_id: 'existing-camp')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(MetaGraphApi).not_to have_received(:delete_campaign)
    end

    it 'still rolls back a campaign it did create' do
      allow(MetaGraphApi).to receive(:create_ad_creative).and_raise(MetaGraphApi::Error, 'boom')

      launch

      expect(MetaGraphApi).to have_received(:delete_campaign).with('new-camp', anything)
    end

    it 'does not require a budget when joining an existing ad set' do
      launch(meta_adset_id: 'existing-adset', meta_campaign_id: 'existing-camp', daily_budget: 0)

      expect(response).to have_http_status(:created)
    end

    it 'does not duplicate the local row when joining a synced campaign' do
      company.ad_campaigns.create!(external_campaign_id: 'existing-camp', name: 'Synced Campaign',
                                   status: 'ACTIVE', created_via: 'meta', ad_account_id: '111')

      expect { launch(meta_campaign_id: 'existing-camp') }
        .not_to change { company.ad_campaigns.where(external_campaign_id: 'existing-camp').count }

      row = company.ad_campaigns.find_by(external_campaign_id: 'existing-camp')
      expect(row.name).to eq('Synced Campaign')
      expect(row.created_via).to eq('meta')
    end
  end
end
