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

  it 'only logs, and does not deny, the newly gated campaign endpoints' do
    allow(Rails.logger).to receive(:warn)

    get '/api/v1/campaigns', headers: headers

    expect(Rails.logger).to have_received(:warn).with(/WOULD DENY marketing\.campaigns or marketing\.automation .*\(log only\)/)
    expect(response.status == 403 ? body['required_any_of'] : nil).to be_nil
  end
end
