# frozen_string_literal: true

require 'rails_helper'

# The Lead Import Log on the Facebook settings card. It filtered on
# utm_source alone, so imported leads and a Zapier-only dealer's page showed
# nothing, and it answered with fields the table does not read.
RSpec.describe 'Facebook lead log', type: :request do
  let(:company) { Company.create!(name: "FBLog-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let!(:integration) do
    company.facebook_integrations.create!(page_id: '55501', page_name: 'Test Page', page_access_token: 'page-token',
                                          status: 'active')
  end

  it 'lists live and imported Facebook leads with the fields the table reads' do
    Lead.create!(company_id: company.id, first_name: 'Tia', last_name: 'May', facebook_leadgen_id: 'lg-1',
                 utm_content: 'Spring Ad', source_created_at: 20.days.ago)
    Lead.create!(company_id: company.id, first_name: 'Ray', last_name: 'Live', facebook_leadgen_id: 'lg-2',
                 utm_source: 'facebook')
    Lead.create!(company_id: company.id, first_name: 'Walk', last_name: 'In')

    get "/api/v1/facebook-integrations/#{integration.id}/lead_log", headers: headers

    rows = JSON.parse(response.body).index_by { |r| r['name'] }
    expect(rows.keys).to contain_exactly('Tia May', 'Ray Live')
    expect(rows['Tia May']).to include('status' => 'imported', 'ad_name' => 'Spring Ad')
    expect(rows['Ray Live']).to include('status' => 'received')
  end
end
