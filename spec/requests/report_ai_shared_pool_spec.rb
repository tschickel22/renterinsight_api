# frozen_string_literal: true

require 'rails_helper'

# Report AI, Deal Desk AI and the help assistant share one monthly allowance,
# so what one uses leaves less for the others.
RSpec.describe 'Report AI allowance', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) { User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', company: company, first_name: 'R', last_name: 'U', role: 'company_admin', status: 'active') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  it 'counts help and Deal Desk questions against what Report AI has left' do
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', 5)
    2.times { AiQueryLog.create!(company_id: company.id, user_id: user.id, feature: 'help_assistant', execution_status: 'success') }
    AiQueryLog.create!(company_id: company.id, user_id: user.id, feature: 'deal_desk_ai', execution_status: 'success')
    AiQueryLog.create!(company_id: company.id, user_id: user.id, feature: 'report_ai', execution_status: 'success')

    get '/api/v1/report-ai/usage', headers: headers
    usage = JSON.parse(response.body)['usage']
    expect(usage).to include('used' => 4, 'limit' => 5, 'remaining' => 1)
  end
end
