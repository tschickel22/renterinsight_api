# frozen_string_literal: true

require 'rails_helper'

# Deals store the stage key. The deal's Stage History showed those keys
# ("proposal -> negotiation"); the API now sends the pipeline's stage names.
RSpec.describe 'Deal stage history: stage names', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:deal) do
    buyer = company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com')
    company.deals.create!(name: 'Smith Home', contact_id: buyer.id, stage: 'negotiation')
  end

  it 'names both stages of each history row with the pipeline names' do
    deal.deal_stage_histories.create!(stage: 'negotiation', previous_stage: 'proposal')

    get "/api/crm/deals/#{deal.id}", headers: headers
    expect(response).to have_http_status(:ok)
    row = JSON.parse(response.body)['stageHistory'].find { |h| h['previousStage'] == 'proposal' }
    expect(row['stageName']).to eq('Negotiation')
    expect(row['previousStageName']).to eq('Proposal')
  end

  it 'uses the name the company gave a stage' do
    stages = Company::DEFAULT_PIPELINE_STAGES.map do |s|
      s['key'] == 'negotiation' ? s.merge('name' => 'Final Terms') : s
    end
    Setting.set('Company', company.id, 'pipeline_stages', stages)
    deal.deal_stage_histories.create!(stage: 'negotiation', previous_stage: 'proposal')

    get "/api/crm/deals/#{deal.id}/stage_histories", headers: headers
    expect(response).to have_http_status(:ok)
    row = JSON.parse(response.body).find { |h| h['previousStage'] == 'proposal' }
    expect(row['stageName']).to eq('Final Terms')
  end

  it 'falls back to a readable form for a key no longer in the pipeline' do
    expect(company.pipeline_stage_name('needs_review')).to eq('Needs Review')
    expect(company.pipeline_stage_name(nil)).to be_nil
  end
end
