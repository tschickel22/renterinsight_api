# frozen_string_literal: true

require 'rails_helper'

# Inbound partner payloads (Zapier / Facebook Lead Ads) carry fields that don't
# map to any column — e.g. FB qualifying questions. Those were appended to the
# lead's `notes` TEXT COLUMN, but the CRM's Notes tab reads the polymorphic
# `notes` TABLE. Result: captured but invisible. These specs pin that both
# stores get written, on the create path and on the repeat-inquiry path.
RSpec.describe 'Api::Partner::V1 Leads inbound notes', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }

  let(:creator) do
    User.create!(email: "creator-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def make_key(webhook_config: {})
    ApiKey.new(
      company_id: company.id,
      name: 'Facebook Leads — Evangeline Home Center',
      key: "ri_live_#{SecureRandom.hex(24)}",
      permissions: { 'leads' => %w[read create] },
      status: 'active',
      created_by_user_id: creator.id,
      webhook_config: webhook_config
    ).tap { |k| k.save!(validate: false) }
  end

  def headers_for(key)
    { 'Authorization' => "Bearer #{key.key}", 'Content-Type' => 'application/json' }
  end

  # Mirrors the live Zap: canonical fields plus FB qualifying questions.
  def fb_payload(email:, phone: '+17048334573')
    {
      full_name: 'Rebecca Whetstine Timson',
      email: email,
      phone: phone,
      current_living_situation: 'Renting',
      finance_or_cash: 'Finance',
      goal_time_frame: '6 months'
    }
  end

  def notes_for(lead)
    Note.where(entity_type: 'lead', entity_id: lead.id.to_s).order(:created_at)
  end

  describe 'create' do
    it 'writes unmapped inbound fields to the notes table, not just the column' do
      key = make_key(webhook_config: { default_location_id: location.id })

      post '/api/partner/v1/leads',
           params: fb_payload(email: 'rtimson55@example.com').to_json,
           headers: headers_for(key)

      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))

      note = notes_for(lead).last
      expect(note).to be_present
      expect(note.content).to include('current living situation: Renting')
      expect(note.content).to include('finance or cash: Finance')
      expect(note.content).to include('goal time frame: 6 months')
      expect(note.created_by_name).to include('Facebook Leads')

      # The text column keeps its existing behavior — this is additive.
      expect(lead.notes).to include('Renting')
    end

    it 'creates no note when every inbound field mapped to a column' do
      key = make_key(webhook_config: { default_location_id: location.id })

      post '/api/partner/v1/leads',
           params: { first_name: 'Tom', last_name: 'Test', email: 'mapped@example.com' }.to_json,
           headers: headers_for(key)

      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(notes_for(lead)).to be_empty
    end
  end

  describe 'custom field mapping on a repeat inquiry' do
    # Mirrors a real company-17 field_key. Matching is exact and case-insensitive.
    let!(:custom_field) do
      CustomField.create!(company_id: company.id, module: 'leads',
                          field_key: 'are_you_wanting_to_finance_or_buy_in_cash',
                          name: 'are_you_wanting_to_finance_or_buy_in_cash',
                          label: 'Are you wanting to finance or buy in cash?',
                          field_type: 'text', is_active: true, display_order: 0)
    end

    it 'maps onto custom_field_values when the payload dedupes to an existing lead' do
      key = make_key(webhook_config: { default_location_id: location.id, dedupe_enabled: true })
      email = 'cf-dedupe@example.com'

      post '/api/partner/v1/leads',
           params: { full_name: 'Latasha Smith', email: email, phone: '+13379402520' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.custom_field_values['are_you_wanting_to_finance_or_buy_in_cash']).to be_blank

      post '/api/partner/v1/leads',
           params: { full_name: 'Latasha Smith', email: email, phone: '+13379402520',
                     are_you_wanting_to_finance_or_buy_in_cash: 'Finance' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:accepted)

      expect(lead.reload.custom_field_values['are_you_wanting_to_finance_or_buy_in_cash']).to eq('Finance')
    end

    it 'never overwrites a custom field value already on the lead' do
      key = make_key(webhook_config: { default_location_id: location.id, dedupe_enabled: true })
      email = 'cf-noclobber@example.com'

      post '/api/partner/v1/leads',
           params: { full_name: 'Latasha Smith', email: email,
                     are_you_wanting_to_finance_or_buy_in_cash: 'Cash' }.to_json,
           headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      expect(lead.custom_field_values['are_you_wanting_to_finance_or_buy_in_cash']).to eq('Cash')

      post '/api/partner/v1/leads',
           params: { full_name: 'Latasha Smith', email: email,
                     are_you_wanting_to_finance_or_buy_in_cash: 'Finance' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:accepted)

      expect(lead.reload.custom_field_values['are_you_wanting_to_finance_or_buy_in_cash']).to eq('Cash')
    end

    it 'keeps a mapped custom field out of the repeat-inquiry note' do
      key = make_key(webhook_config: { default_location_id: location.id, dedupe_enabled: true })
      email = 'cf-note@example.com'

      post '/api/partner/v1/leads',
           params: { full_name: 'Latasha Smith', email: email }.to_json,
           headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))

      post '/api/partner/v1/leads',
           params: { full_name: 'Latasha Smith', email: email,
                     raw: { are_you_wanting_to_finance_or_buy_in_cash: 'Finance',
                            unmapped_question: 'Trading' },
                     are_you_wanting_to_finance_or_buy_in_cash: 'Finance' }.to_json,
           headers: headers_for(key)
      expect(response).to have_http_status(:accepted)

      note = notes_for(lead.reload).last
      expect(note.content).to include('unmapped_question: Trading')
      expect(note.content).not_to include('are_you_wanting_to_finance_or_buy_in_cash')
    end
  end

  describe 'repeat inquiry (deduped to an existing lead)' do
    it 'writes a note row for the re-engagement instead of only appending to the column' do
      key = make_key(webhook_config: { default_location_id: location.id, dedupe_enabled: true })
      email = 'repeat@example.com'

      post '/api/partner/v1/leads', params: fb_payload(email: email).to_json, headers: headers_for(key)
      expect(response).to have_http_status(:created)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
      before_count = notes_for(lead).count

      post '/api/partner/v1/leads', params: fb_payload(email: email).to_json, headers: headers_for(key)
      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body).dig('deduped_to', 'id')).to eq(lead.id)

      expect(notes_for(lead).count).to eq(before_count + 1)
      expect(notes_for(lead).last.content).to include('REPEAT INQUIRY')
    end

    it 'still writes the note when the repeat inquiry adds no new field values' do
      key = make_key(webhook_config: { default_location_id: location.id, dedupe_enabled: true })
      email = 'nochange@example.com'

      post '/api/partner/v1/leads', params: fb_payload(email: email).to_json, headers: headers_for(key)
      lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))

      # Identical payload: nothing left to enrich, but the dealer still needs
      # to know the person came back.
      post '/api/partner/v1/leads', params: fb_payload(email: email).to_json, headers: headers_for(key)
      expect(response).to have_http_status(:accepted)

      expect(notes_for(lead).map(&:content)).to include(a_string_including('REPEAT INQUIRY'))
    end
  end
end
