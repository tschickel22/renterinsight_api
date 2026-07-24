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

    context 'specific_per_location mode' do
      let(:location2) { Location.create!(company_id: company.id, name: 'Aurora', code: 'AUR', active: true) }

      it 'assigns based on the resolved location_id' do
        key = make_key(webhook_config: {
          default_location_ids: [location.id, location2.id],
          assignment_mode: 'specific_per_location',
          assigned_user_ids_by_location: { location.id.to_s => u1.id, location2.id.to_s => owner_specific.id }
        })

        # Lead 1: location.id → u1
        post '/api/partner/v1/leads',
             params: { first_name: 'A', last_name: 'A', email: 'pla@x.com', location_id: location.id }.to_json,
             headers: headers_for(key)
        expect(Lead.find(JSON.parse(response.body).dig('data', 'id')).owner_id).to eq(u1.id)

        # Lead 2: location2.id → owner_specific
        post '/api/partner/v1/leads',
             params: { first_name: 'B', last_name: 'B', email: 'plb@x.com', location_id: location2.id }.to_json,
             headers: headers_for(key)
        expect(Lead.find(JSON.parse(response.body).dig('data', 'id')).owner_id).to eq(owner_specific.id)
      end

      it 'leaves owner nil when no mapping exists for the resolved location' do
        location3 = Location.create!(company_id: company.id, name: 'Boulder', code: 'BLD', active: true)
        # Note: default_location_ids intentionally includes location3 with no
        # mapping — normally validation blocks this, but a config edited later
        # could get here; ensure we degrade gracefully.
        key = make_key(webhook_config: {
          default_location_ids: [location.id, location3.id],
          assignment_mode: 'specific_per_location',
          assigned_user_ids_by_location: { location.id.to_s => u1.id }
        })

        post '/api/partner/v1/leads',
             params: { first_name: 'X', last_name: 'X', email: 'plx@x.com', location_id: location3.id }.to_json,
             headers: headers_for(key)
        expect(Lead.find(JSON.parse(response.body).dig('data', 'id')).owner_id).to be_nil
      end
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

  describe 'expanded standard fields (co-applicant, preferred_*) map to attributes' do
    it 'accepts co-applicant + preference fields and does not dump them to notes' do
      key = make_key
      post '/api/partner/v1/leads',
           params: { first_name: 'A', last_name: 'B', email: 'exp@x.com',
                     co_applicant_first_name: 'Sam', co_applicant_email: 'sam@x.com',
                     preferred_home_type: 'double', company_name: 'Acme' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.co_applicant_first_name).to eq('Sam')
      expect(lead.co_applicant_email).to eq('sam@x.com')
      expect(lead.preferred_home_type).to eq('double')
      expect(lead.company_name).to eq('Acme')
      expect(lead.notes).to be_blank # mapped to real fields, not notes
    end
  end

  describe 'custom field mapping' do
    it 'maps an inbound key matching a company custom field onto custom_field_values (not notes)' do
      company.custom_fields.create!(name: 'Monthly Payment', field_key: 'monthly_payment',
                                    field_type: 'text', module: 'leads', is_active: true)
      key = make_key
      post '/api/partner/v1/leads',
           params: { first_name: 'A', last_name: 'B', email: 'cf@x.com', monthly_payment: '$1,500' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.custom_field_values['monthly_payment']).to eq('$1,500')
      expect(lead.notes.to_s).not_to include('monthly payment') # consumed, not dumped to notes
    end

    it 'leaves a non-custom, unmapped key in notes' do
      company.custom_fields.create!(name: 'Monthly Payment', field_key: 'monthly_payment',
                                    field_type: 'text', module: 'leads', is_active: true)
      key = make_key
      post '/api/partner/v1/leads',
           params: { first_name: 'A', last_name: 'B', email: 'cf2@x.com',
                     monthly_payment: '$1,500', some_other_q: 'blue' }.to_json,
           headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.custom_field_values['monthly_payment']).to eq('$1,500')
      expect(lead.notes.to_s).to include('some other q: blue')
    end
  end

  describe 'unmapped inbound fields -> notes (safety net)' do
    it 'appends Facebook qualifying answers (raw) to notes on a new lead' do
      key = make_key
      post '/api/partner/v1/leads',
           params: {
             full_name: 'Joyce Davis', email: 'joyce@x.com', phone_number: '3185551234',
             raw: {
               'full_name' => 'Joyce Davis',
               'what_price_range_were_you_looking_to_be_in?' => '$80,000-$120,000',
               'how_many_bedrooms_were_you_wanting?' => '3 Bed',
               'home_type' => 'Double'
             }
           }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.notes.to_s).to include('what price range were you looking to be in?: $80,000-$120,000')
      expect(lead.notes.to_s).to include('home type: Double')
    end

    it 'does not put mapped fields (name/email/phone) or FB ad metadata into notes' do
      key = make_key
      post '/api/partner/v1/leads',
           params: {
             full_name: 'Joyce Davis', email: 'joyce2@x.com', phone_number: '3185551234',
             ad_id: '123', campaign_name: 'Green sterling ad', page_name: 'Evangeline Home Center',
             raw: { 'full_name' => 'Joyce Davis', 'home_type' => 'Single' }
           }.to_json,
           headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.notes.to_s).to include('home type: Single')
      expect(lead.notes.to_s).not_to include('Joyce Davis')          # name is mapped
      expect(lead.notes.to_s).not_to include('Green sterling ad')    # ad metadata is noise
    end

    it 'leaves notes untouched when everything maps' do
      key = make_key
      post '/api/partner/v1/leads',
           params: { first_name: 'Al', last_name: 'B', email: 'al@x.com', phone: '111' }.to_json,
           headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.notes).to be_blank
    end
  end

  describe 'Facebook / Zapier field aliases' do
    it 'maps full_name -> first_name + last_name when first/last are absent' do
      key = make_key
      post '/api/partner/v1/leads',
           params: { full_name: 'Jacob Andries', email: 'jacob@x.com', phone_number: '+13378961773' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.first_name).to eq('Jacob')
      expect(lead.last_name).to eq('Andries')
      expect(lead.phone).to eq('+13378961773')
    end

    it 'handles a single-word full_name (first only, no last)' do
      key = make_key
      post '/api/partner/v1/leads',
           params: { full_name: 'Cher', email: 'cher@x.com' }.to_json, headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.first_name).to eq('Cher')
      expect(lead.last_name).to be_blank
    end

    it 'does NOT override an explicitly mapped first_name/phone' do
      key = make_key
      post '/api/partner/v1/leads',
           params: { first_name: 'Mapped', last_name: 'Correctly', full_name: 'Ignored Alias',
                     phone: '111', phone_number: '999', email: 'm@x.com' }.to_json,
           headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.first_name).to eq('Mapped')
      expect(lead.last_name).to eq('Correctly')
      expect(lead.phone).to eq('111')
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

  # A returning inbound inquiry that dedupes should NOT be a silent no-op:
  # we enrich the matched lead and notify its owner, while still returning 202
  # and never creating a duplicate.
  describe 'dedupe enrichment + notification' do
    let(:key) { make_key(webhook_config: { dedupe_enabled: true, default_source_id: fb_source.id }) }
    let!(:existing) do
      Lead.create!(company_id: company.id, first_name: 'Tom', last_name: 'Prior',
                   email: 'ret@x.com', phone: nil, owner_id: owner_specific.id)
    end

    def post_repeat
      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'New', email: 'ret@x.com',
                     phone: '3035551212', interests_requirements: 'Wants a 3/2 single-wide' }.to_json,
           headers: headers_for(key)
    end

    it 'still returns 202 and creates no duplicate' do
      post_repeat
      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)['deduped_to']).to include('type' => 'lead', 'id' => existing.id)
      expect(Lead.where(email: 'ret@x.com').count).to eq(1)
    end

    it 'fills blank fields from the inquiry without overwriting existing data' do
      post_repeat
      existing.reload
      expect(existing.phone).to eq('3035551212')                       # was blank → filled
      expect(existing.interests_requirements).to eq('Wants a 3/2 single-wide')
      expect(existing.last_name).to eq('Prior')                        # non-blank → NOT overwritten
    end

    it 'appends a timestamped note capturing the repeat inquiry' do
      post_repeat
      expect(existing.reload.notes.to_s).to include('Repeat inquiry')
    end

    it 'creates a high-priority reminder activity for the lead owner' do
      expect { post_repeat }.to change {
        LeadActivity.where(lead_id: existing.id, assigned_to_id: owner_specific.id).count
      }.by(1)
      activity = LeadActivity.where(lead_id: existing.id).order(:id).last
      expect(activity.subject).to include('Repeat Inquiry on Existing Lead')
      expect(activity.priority).to eq('high')
    end
  end
end
