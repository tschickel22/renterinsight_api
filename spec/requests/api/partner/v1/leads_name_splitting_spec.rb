# frozen_string_literal: true

require 'rails_helper'

# Facebook's default lead form collects a single "Full name" field, so a Zap
# built from our payload template has no first-name token and dealers map Full
# Name into first_name. These cover that the API splits it anyway, without
# disturbing a payload that was mapped correctly.
RSpec.describe 'Api::Partner::V1 Leads name splitting', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  let(:creator) do
    User.create!(email: "creator-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  let(:api_key) do
    ApiKey.new(
      company_id: company.id,
      name: 'zapier',
      key: "ri_live_#{SecureRandom.hex(24)}",
      permissions: { 'leads' => ['read', 'create'] },
      status: 'active',
      created_by_user_id: creator.id,
      webhook_config: {}
    ).tap { |k| k.save!(validate: false) }
  end

  def post_lead(payload)
    post '/api/partner/v1/leads',
         params: payload.to_json,
         headers: { 'Authorization' => "Bearer #{api_key.key}", 'Content-Type' => 'application/json' }
  end

  def created_lead
    Lead.find(JSON.parse(response.body).dig('data', 'id'))
  end

  it 'splits a full name mapped into first_name' do
    post_lead(first_name: 'Tia May', email: "tia-#{SecureRandom.hex(3)}@example.com")

    expect(response).to have_http_status(:created)
    lead = created_lead
    expect(lead.first_name).to eq('Tia')
    expect(lead.last_name).to eq('May')
  end

  it 'keeps a multi-word surname together' do
    post_lead(first_name: 'Ana Maria De La Cruz', email: "ana-#{SecureRandom.hex(3)}@example.com")

    lead = created_lead
    expect(lead.first_name).to eq('Ana')
    expect(lead.last_name).to eq('Maria De La Cruz')
  end

  it 'leaves a correctly mapped payload alone' do
    post_lead(first_name: 'Mary Ann', last_name: 'Whitfield', email: "mary-#{SecureRandom.hex(3)}@example.com")

    lead = created_lead
    expect(lead.first_name).to eq('Mary Ann')
    expect(lead.last_name).to eq('Whitfield')
  end

  it 'leaves a single-word first name alone' do
    post_lead(first_name: 'Tia', email: "solo-#{SecureRandom.hex(3)}@example.com")

    lead = created_lead
    expect(lead.first_name).to eq('Tia')
    expect(lead.last_name).to be_blank
  end

  it 'still splits the full_name alias when no name fields are mapped' do
    post_lead(full_name: 'Tia May', email: "alias-#{SecureRandom.hex(3)}@example.com")

    lead = created_lead
    expect(lead.first_name).to eq('Tia')
    expect(lead.last_name).to eq('May')
  end
end
