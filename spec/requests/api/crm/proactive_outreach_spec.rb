# frozen_string_literal: true

require 'rails_helper'

# Proactive Outreach (E105): only companies given the module can reach it, and
# only approved content is ever available to send.
RSpec.describe 'Proactive Outreach', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }

  def grant!(target = company)
    TenantModuleOverride.create!(company: target, module_key: 'marketing.proactive_outreach', is_enabled: true)
  end

  def running_campaign(target, user)
    Campaign.create!(company_id: target.id, created_by_user_id: user.id, name: 'Series', campaign_type: 'blast',
                     from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100, status: 'running')
  end

  describe 'the subscription gate' do
    it 'is in no subscription plan' do
      PlatformModule::PLAN_TEMPLATES.each_value do |modules|
        expect(modules).not_to include('marketing.proactive_outreach')
      end
    end

    it 'refuses every action for a company without the module' do
      item = company.outreach_content_items.create!(title: 'Tour', url: 'https://vimeo.com/1')

      get '/api/crm/proactive_outreach', headers: headers
      expect(response).to have_http_status(:forbidden)
      patch '/api/crm/proactive_outreach', headers: headers, params: { settings: { enabled: true } }.to_json
      expect(response).to have_http_status(:forbidden)
      post '/api/crm/proactive_outreach/load_starter', headers: headers
      expect(response).to have_http_status(:forbidden)
      post '/api/crm/outreach_content_items', headers: headers, params: { item: { title: 'X', url: 'https://vimeo.com/2' } }.to_json
      expect(response).to have_http_status(:forbidden)
      patch "/api/crm/outreach_content_items/#{item.id}", headers: headers, params: { item: { status: 'approved' } }.to_json
      expect(response).to have_http_status(:forbidden)
      delete "/api/crm/outreach_content_items/#{item.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
      post '/api/crm/outreach_content_items/import_from_campaigns', headers: headers
      expect(response).to have_http_status(:forbidden)

      expect(item.reload.status).to eq('pending')
      expect(Outreach::Settings.for(company).active?).to be(false)
    end

    it 'is not active until the company turns it on, and stops if the module is removed' do
      override = grant!
      settings = Outreach::Settings.for(company)
      expect(settings.active?).to be(false)

      settings.update!('enabled' => true)
      expect(Outreach::Settings.for(company).active?).to be(true)

      override.update!(is_enabled: false)
      expect(Outreach::Settings.for(company).active?).to be(false)
    end
  end

  describe 'settings' do
    before { grant! }

    it 'saves the persona and defaults demos to 30 minutes' do
      get '/api/crm/proactive_outreach', headers: headers
      expect(JSON.parse(response.body).dig('settings', 'demo_minutes')).to eq(30)

      patch '/api/crm/proactive_outreach', headers: headers,
            params: { settings: { persona_name: 'Tom Schickel', persona_title: 'Founder', sender_user_id: admin.id } }.to_json
      body = JSON.parse(response.body)
      expect(body['settings']).to include('persona_name' => 'Tom Schickel', 'sender_user_id' => admin.id)
      expect(body['readiness']).to include('sender' => true, 'meeting_link' => false)
    end

    it 'will not take a sender from another company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      stranger = User.create!(email: "s-#{SecureRandom.hex(4)}@example.com", first_name: 'S', last_name: 'T', password: 'Pass1234!',
                              company_id: other.id, role: 'company_admin', status: 'active')

      patch '/api/crm/proactive_outreach', headers: headers, params: { settings: { sender_user_id: stranger.id } }.to_json
      expect(JSON.parse(response.body).dig('settings', 'sender_user_id')).to be_nil
    end

    it 'removes dashes from playbook answers' do
      patch '/api/crm/proactive_outreach', headers: headers,
            params: { settings: { playbook: [{ objection: 'Too busy', answer: "Understood — when is better?", action: 'reply' }] } }.to_json
      expect(JSON.parse(response.body).dig('settings', 'playbook', 0, 'answer')).to eq('Understood, when is better?')
    end
  end

  describe 'starter content' do
    it 'loads for DealerTide and never replaces answers already written' do
      dealertide = Company.create!(name: 'DealerTide')
      grant!(dealertide)
      user = User.create!(email: "d-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                          company_id: dealertide.id, role: 'company_admin', status: 'active')
      auth = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: dealertide.id)}", 'Content-Type' => 'application/json' }

      post '/api/crm/proactive_outreach/load_starter', headers: auth
      playbook = JSON.parse(response.body).dig('settings', 'playbook')
      expect(playbook.size).to eq(Outreach::StarterContent::PLAYBOOK.size)
      expect(playbook.to_json).not_to match(/[–—]/)

      Outreach::Settings.for(dealertide).update!('playbook' => [{ 'objection' => 'Mine', 'answer' => 'My words' }])
      post '/api/crm/proactive_outreach/load_starter', headers: auth
      expect(JSON.parse(response.body).dig('settings', 'playbook').map { |e| e['objection'] }).to eq(['Mine'])
    end

    it 'is not offered to any other company' do
      grant!
      post '/api/crm/proactive_outreach/load_starter', headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Outreach::Settings.for(company)['playbook']).to eq([])
    end
  end

  describe 'content from campaigns' do
    before { grant! }

    it 'lists each running campaign video once, waiting for approval' do
      campaign = running_campaign(company, admin)
      blocks = [{ 'type' => 'text', 'html' => '<p>Hi {{first_name}}, see TrueBuild.</p>' },
                { 'type' => 'image', 'src' => 'https://i.vimeocdn.com/video/9.jpg', 'href' => 'https://vimeo.com/1239600953' },
                { 'type' => 'button', 'href' => 'https://bookings.example.com/abc', 'text' => 'Book' }]
      campaign.campaign_steps.create!(position: 0, is_active: true, channel: 'email', subject: 'Let buyers design', body_blocks: blocks)
      campaign.campaign_steps.create!(position: 1, is_active: true, channel: 'email', subject: 'Again', body_blocks: blocks)
      campaign.campaign_steps.create!(position: 2, is_active: true, channel: 'sms', sms_body: 'Watch https://vimeo.com/1240316789')

      post '/api/crm/outreach_content_items/import_from_campaigns', headers: headers
      expect(JSON.parse(response.body)).to eq('found' => 2, 'added' => 2)

      items = company.outreach_content_items.order(:url)
      expect(items.map(&:url)).to eq(%w[https://vimeo.com/1239600953 https://vimeo.com/1240316789])
      expect(items.map(&:status).uniq).to eq(['pending'])
      expect(items.first.title).to eq('Let buyers design')
      expect(company.outreach_content_items.approved).to be_empty
    end

    it 'skips other companies, stopped campaigns and items already reviewed' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      other_user = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'U', password: 'Pass1234!',
                                company_id: other.id, role: 'company_admin', status: 'active')
      running_campaign(other, other_user).campaign_steps.create!(position: 0, is_active: true, channel: 'sms', sms_body: 'https://vimeo.com/111')
      paused = running_campaign(company, admin)
      paused.campaign_steps.create!(position: 0, is_active: true, channel: 'sms', sms_body: 'https://vimeo.com/222')
      paused.update!(status: 'paused')
      running_campaign(company, admin).campaign_steps.create!(position: 0, is_active: true, channel: 'sms', sms_body: 'https://vimeo.com/333')
      reviewed = company.outreach_content_items.create!(title: 'My title', url: 'https://vimeo.com/333', status: 'approved')

      post '/api/crm/outreach_content_items/import_from_campaigns', headers: headers
      expect(JSON.parse(response.body)).to eq('found' => 1, 'added' => 0)
      expect(reviewed.reload).to have_attributes(title: 'My title', status: 'approved')
      expect(company.outreach_content_items.count).to eq(1)
    end
  end

  describe 'content by hand' do
    before { grant! }

    it 'approves what a person adds and records who approved an imported item' do
      post '/api/crm/outreach_content_items', headers: headers,
           params: { item: { title: "Tour — 80 seconds", url: 'https://vimeo.com/5', topic: 'Overview' } }.to_json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['item']).to include('title' => 'Tour, 80 seconds', 'status' => 'approved')

      pending_item = company.outreach_content_items.create!(title: 'Imported', url: 'https://vimeo.com/6', source_kind: 'campaign')
      patch "/api/crm/outreach_content_items/#{pending_item.id}", headers: headers, params: { item: { status: 'approved' } }.to_json
      expect(pending_item.reload).to have_attributes(status: 'approved', approved_by_user_id: admin.id)
    end

    it 'refuses a bad address and another company\'s item' do
      post '/api/crm/outreach_content_items', headers: headers, params: { item: { title: 'Bad', url: 'not a link' } }.to_json
      expect(response).to have_http_status(:unprocessable_entity)

      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      theirs = other.outreach_content_items.create!(title: 'Theirs', url: 'https://vimeo.com/7')
      patch "/api/crm/outreach_content_items/#{theirs.id}", headers: headers, params: { item: { status: 'approved' } }.to_json
      expect(response).to have_http_status(:not_found)
      expect(theirs.reload.status).to eq('pending')
    end
  end
end

RSpec.describe 'Proactive Outreach waves', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:lead) { company.leads.create!(first_name: 'P', last_name: 'L', email: 'p@example.com', owner_id: admin.id, status: 'new') }

  def grant!
    TenantModuleOverride.create!(company: company, module_key: 'marketing.proactive_outreach', is_enabled: true)
  end

  it 'refuses a company without the module' do
    post '/api/crm/outreach_waves', headers: headers, params: { wave: { prompt: 'Retailers' } }.to_json
    expect(response).to have_http_status(:forbidden)
    get '/api/crm/outreach_waves', headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it 'shows who was left out, adds them by hand past soft rules, and keeps hard ones locked' do
    grant!
    tree = { 'type' => 'and', 'children' => [{ 'field' => 'status', 'operator' => 'equals', 'value' => 'new' }] }
    wave = company.outreach_waves.create!(name: 'W', status: 'failed', build_error: 'none', filter_tree: tree, target_size: 5)
    nurtured = company.leads.create!(first_name: 'N', last_name: 'Ur', email: 'n@example.com', owner_id: admin.id, status: 'new')
    NurtureEnrollment.create!(enrollable: nurtured, company_id: company.id, nurture_sequence_id: NurtureSequence.create!(name: 'Follow', company_id: company.id).id, status: 'running')
    unreachable = company.leads.create!(first_name: 'U', last_name: 'Nr', email: 'u@example.com', owner_id: admin.id, status: 'new')
    CommunicationPreference.find_or_create_for(recipient: unreachable, channel: 'email').opt_out!('Unsubscribed')
    fresh = lead

    get "/api/crm/outreach_waves/#{wave.id}/skipped", headers: headers
    rows = JSON.parse(response.body)['skipped'].index_by { |r| r['lead_id'] }
    expect(rows[nurtured.id]).to include('reason' => 'On the nurture Follow', 'can_add' => true)
    expect(rows[unreachable.id]).to include('can_add' => false)
    expect(rows[fresh.id]['reason']).to start_with('Ready to contact.')

    post "/api/crm/outreach_waves/#{wave.id}/add_targets", headers: headers, params: { lead_ids: [nurtured.id, unreachable.id, fresh.id] }.to_json
    body = JSON.parse(response.body)
    expect(body['added']).to eq(2)
    expect(body['refused'].map { |r| r['lead_id'] }).to eq([unreachable.id])
    expect(wave.reload.status).to eq('audience_ready')
    added = wave.outreach_targets.find_by(lead_id: nurtured.id)
    expect(added).to have_attributes(test_group: 'contact', override_reason: 'On the nurture Follow', overridden_by_user_id: admin.id)
    expect(wave.outreach_targets.find_by(lead_id: fresh.id).override_reason).to be_nil
  end

  it 'will not show another company\'s wave' do
    grant!
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    theirs = other.outreach_waves.create!(name: 'Theirs')
    get "/api/crm/outreach_waves/#{theirs.id}/results", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'will not start until every message is reviewed and setup is finished' do
    grant!
    wave = company.outreach_waves.create!(name: 'W', status: 'review')
    target = wave.outreach_targets.create!(company_id: company.id, lead_id: lead.id, status: 'drafted', channel: 'email', draft_body: 'Hello there')

    post "/api/crm/outreach_waves/#{wave.id}/start", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(wave.reload.status).to eq('review')

    patch "/api/crm/outreach_waves/#{wave.id}/targets/#{target.id}", headers: headers,
          params: { target: { draft_body: 'Only $99 per month', decision: 'approve' } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(target.reload.status).to eq('drafted')

    patch "/api/crm/outreach_waves/#{wave.id}/targets/#{target.id}", headers: headers,
          params: { target: { draft_body: 'Would a short demo help?', decision: 'approve' } }.to_json
    expect(target.reload).to have_attributes(status: 'approved', approved_by_user_id: admin.id)
  end

  it 'shows the unsubscribe page without opting out until confirmed' do
    wave = company.outreach_waves.create!(name: 'W')
    target = wave.outreach_targets.create!(company_id: company.id, lead_id: lead.id)
    path = URI(Outreach::Tracking.unsubscribe_url(target)).path

    get path
    expect(response.body).to include('Unsubscribe')
    expect(CommunicationOptOut.check(channel: 'email', company: company, record: lead, address: lead.email).opted_out?).to be(false)

    post path
    expect(CommunicationOptOut.check(channel: 'email', company: company, record: lead, address: lead.email).opted_out?).to be(true)
    expect(target.reload.status).to eq('stopped')
  end

  it 'records a video click and refuses a forged link' do
    wave = company.outreach_waves.create!(name: 'W')
    target = wave.outreach_targets.create!(company_id: company.id, lead_id: lead.id)
    item = company.outreach_content_items.create!(title: 'Tour', url: 'https://vimeo.com/9', status: 'approved')

    get URI(Outreach::Tracking.video_url(target, item)).path, headers: { 'User-Agent' => 'Mozilla/5.0 (iPhone)' }
    expect(response).to redirect_to('https://vimeo.com/9')
    expect(target.recorded?('clicked')).to be(true)

    get '/o/v/forged'
    expect(response).to have_http_status(:not_found)
  end
end
