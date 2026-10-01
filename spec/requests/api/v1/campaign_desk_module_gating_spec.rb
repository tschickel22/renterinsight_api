# frozen_string_literal: true

require 'rails_helper'

# A Starter tenant sold Campaign Desk must be able to use the engines Campaign
# Desk drives (workflows, campaigns) without being granted those products.
RSpec.describe 'Campaign Desk module gating', type: :request do
  let(:company) { Company.create!(name: "Starter-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'Admin',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def body
    JSON.parse(response.body)
  end

  it 'opens the workflow engine to Campaign Desk without Workflow Automation' do
    expect(ModuleAccessService.new(company).has_module?('management.workflows')).to be false

    get '/api/v1/workflow_rules', headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(body['required_any_of']).to eq(%w[management.workflows marketing.automation])

    company.tenant_module_overrides.create!(module_key: 'marketing.automation', is_enabled: true)
    get '/api/v1/workflow_rules', headers: headers
    expect(response.status == 403 ? body['required_any_of'] : nil).to be_nil
  end

  # Was log only until plan data granted these modules everywhere (v3 plan
  # 18). Checked 2026-10-01 on staging and production: every tenant using
  # campaigns has one of them, so the gate now denies like the workflow one.
  it 'denies the campaign endpoints without Email Campaigns or Campaign Desk, and opens them with either' do
    get '/api/v1/campaigns', headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(body['required_any_of']).to eq(%w[marketing.campaigns marketing.automation])

    company.tenant_module_overrides.create!(module_key: 'marketing.automation', is_enabled: true)
    get '/api/v1/campaigns', headers: headers
    # Past the module gate; any remaining 403 is the role's own permission.
    expect(response.status == 403 ? body['required_any_of'] : nil).to be_nil
  end
end
