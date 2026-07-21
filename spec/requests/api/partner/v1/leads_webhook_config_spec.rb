# frozen_string_literal: true

require 'rails_helper'

# Covers the webhook_config path on POST /api/partner/v1/leads — the
# Zapier/FB inbound flow. Each config knob applies only when the payload
# doesn't explicitly override it.
RSpec.describe 'Api::Partner::V1 Leads webhook_config', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }
  def make_user(status: 'active')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: status)
  end
  let(:owner_specific) { make_user }
  let(:u1) { make_user }
  let(:u2) { make_user }
  let!(:fb_source) { Source.create!(company_id: company.id, name: 'Facebook Lead Ads', is_active: true) }

  let(:creator) do
    User.create!(email: "creator-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def make_key(webhook_config: {})
    ApiKey.new(
      company_id: company.id,
      name: 'zapier',
      key: "ri_live_#{SecureRandom.hex(24)}",
      permissions: { 'leads' => ['read', 'create'] },
      status: 'active',
      created_by_user_id: creator.id,
      webhook_config: webhook_config
    ).tap { |k| k.save!(validate: false) }
  end

  def headers_for(key)
    { 'Authorization' => "Bearer #{key.key}", 'Content-Type' => 'application/json' }
  end

  describe 'source resolution' do
    it 'resolves a source name from the payload via SourceResolverService' do
      key = make_key
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'Test', email: 't@x.com', source: 'Facebook Lead Ads' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.source_id).to eq(fb_source.id)
    end

    it 'falls back to default_source_id from webhook_config when payload has no source' do
      key = make_key(webhook_config: { default_source_id: fb_source.id })
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'Test', email: 't2@x.com' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.source_id).to eq(fb_source.id)
    end
  end

  describe 'location default' do
    it 'applies default_location_id when payload omits location_id' do
      key = make_key(webhook_config: { default_location_id: location.id })
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'Test', email: 't3@x.com' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.location_id).to eq(location.id)
    end

    context 'with default_location_ids array (multi-location key)' do
      let(:location2) { Location.create!(company_id: company.id, name: 'Aurora', code: 'AUR', active: true) }
      let(:location3) { Location.create!(company_id: company.id, name: 'Boulder', code: 'BLD', active: true) }

      it 'uses first allowed location when payload omits location_id' do
        key = make_key(webhook_config: { default_location_ids: [location.id, location2.id, location3.id] })
        post '/api/partner/v1/leads',
             params: { first_name: 'Tom', last_name: 'Test', email: 'ml1@x.com' }.to_json,
             headers: headers_for(key)
        expect(response).to have_http_status(:created)
        lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
        expect(lead.location_id).to eq(location.id)
      end

      it 'honors payload location_id when it is in the allowed list' do
        key = make_key(webhook_config: { default_location_ids: [location.id, location2.id, location3.id] })
        post '/api/partner/v1/leads',
             params: { first_name: 'Tom', last_name: 'Test', email: 'ml2@x.com', location_id: location2.id }.to_json,
             headers: headers_for(key)
        expect(response).to have_http_status(:created)
        lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
        expect(lead.location_id).to eq(location2.id)
      end

      it 'falls back to first allowed when payload location_id is NOT in the allowed list' do
        other_location = Location.create!(company_id: company.id, name: 'Denied', code: 'DNY', active: true)
        key = make_key(webhook_config: { default_location_ids: [location.id, location2.id] })
        post '/api/partner/v1/leads',
             params: { first_name: 'Tom', last_name: 'Test', email: 'ml3@x.com', location_id: other_location.id }.to_json,
             headers: headers_for(key)
        expect(response).to have_http_status(:created)
        lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
        expect(lead.location_id).to eq(location.id) # rejected + fallback
      end
    end
  end

  describe 'owner assignment' do
    it 'specific mode assigns to the configured user' do
      key = make_key(webhook_config: { assignment_mode: 'specific', assigned_user_id: owner_specific.id })
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'Test', email: 't4@x.com' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.owner_id).to eq(owner_specific.id)
    end

    it 'round_robin mode cycles through the referenced list, skipping inactives' do
      u2.update!(status: 'inactive')
      list = RoundRobinAssignmentList.create!(company: company, name: 'Sales',
                                              user_ids: [u1.id, u2.id, owner_specific.id])
      key = make_key(webhook_config: { assignment_mode: 'round_robin', round_robin_list_id: list.id })

      owners = 3.times.map do |i|
        post '/api/partner/v1/leads',
             params: { first_name: 'RR', last_name: "L#{i}", email: "rr#{i}@x.com" }.to_json,
             headers: headers_for(key)
        Lead.find(JSON.parse(response.body).dig('data', 'id')).owner_id
      end
      # u2 is inactive → skipped; effective rotation is u1, owner_specific, u1
      expect(owners).to eq([u1.id, owner_specific.id, u1.id])
    end

    it 'round_robin mode with inline assigned_user_ids advances the cursor on the key itself' do
      u2.update!(status: 'inactive')
      key = make_key(webhook_config: {
        assignment_mode: 'round_robin',
        assigned_user_ids: [u1.id, u2.id, owner_specific.id]
      })

      owners = 3.times.map do |i|
        post '/api/partner/v1/leads',
             params: { first_name: 'RR', last_name: "IL#{i}", email: "ril#{i}@x.com" }.to_json,
             headers: headers_for(key)
        Lead.find(JSON.parse(response.body).dig('data', 'id')).owner_id
      end
      # u2 is inactive → skipped; effective rotation is u1, owner_specific, u1
      expect(owners).to eq([u1.id, owner_specific.id, u1.id])

      # Cursor persisted back to the key so a later request keeps the rotation going.
      key.reload
      expect(key.webhook_config['round_robin_cursor']).to eq(1)
    end

    it 'round_robin returns nil owner when every configured inline user is inactive' do
      [u1, u2, owner_specific].each { |u| u.update!(status: 'inactive') }
      key = make_key(webhook_config: {
        assignment_mode: 'round_robin',
        assigned_user_ids: [u1.id, u2.id, owner_specific.id]
      })

      post '/api/partner/v1/leads',
           params: { first_name: 'X', last_name: 'Y', email: 'x@x.com' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.owner_id).to be_nil
    end

    it 'payload owner_id wins over any assignment_mode' do
      key = make_key(webhook_config: { assignment_mode: 'specific', assigned_user_id: owner_specific.id })
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'Test', email: 't5@x.com', owner_id: u1.id }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.owner_id).to eq(u1.id)
    end
  end

  describe 'dedupe' do
    it 'returns 202 with deduped_to when an existing Lead matches on email' do
      existing = Lead.create!(company_id: company.id, first_name: 'Tom', last_name: 'Prior', email: 'dup@x.com')
      key = make_key(webhook_config: { dedupe_enabled: true })
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'New', email: 'dup@x.com' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body['deduped_to']).to include('type' => 'lead', 'id' => existing.id)
      # And no new lead was created
      expect(Lead.where(email: 'dup@x.com').count).to eq(1)
    end

    it 'creates normally when dedupe is disabled even if email matches' do
      Lead.create!(company_id: company.id, first_name: 'Tom', last_name: 'Prior', email: 'dup2@x.com')
      key = make_key(webhook_config: { dedupe_enabled: false })
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'New', email: 'dup2@x.com' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      expect(Lead.where(email: 'dup2@x.com').count).to eq(2)
    end
  end
end
