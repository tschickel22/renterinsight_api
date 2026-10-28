# frozen_string_literal: true

require 'rails_helper'

# The monthly email and SMS allowances sit beside the daily campaign caps on the
# tenant edit screen. Before this they could only be changed from the Email
# Usage page, which Tom could not find.
RSpec.describe 'Api::Platform tenant monthly limits', type: :request do
  let(:tenant) { Company.create!(name: "Tenant #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:platform_admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: tenant.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: platform_admin.id, company_id: tenant.id)}" } }

  it 'shows the limits and what has been sent this month' do
    get "/api/platform/tenants/#{tenant.id}", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)['tenant']
    expect(body['email_monthly_limit']).to eq(10_000)
    expect(body['sms_monthly_limit']).to eq(2_000)
    expect(body['sent_this_month']).to eq('email' => 0, 'sms' => 0)
  end

  it 'saves new monthly limits' do
    patch "/api/platform/tenants/#{tenant.id}",
          params: { tenant: { email_monthly_limit: 15_000, sms_monthly_limit: 0 } }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(tenant.reload.email_monthly_limit).to eq(15_000)
    expect(tenant.sms_monthly_limit).to eq(0)
  end

  it 'leaves a limit alone when its field is blank' do
    patch "/api/platform/tenants/#{tenant.id}",
          params: { tenant: { email_monthly_limit: '', name: 'Renamed' } }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(tenant.reload.email_monthly_limit).to eq(10_000)
    expect(tenant.name).to eq('Renamed')
  end

  it 'refuses a negative limit, which would otherwise read as unlimited' do
    patch "/api/platform/tenants/#{tenant.id}",
          params: { tenant: { email_monthly_limit: -5 } }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(tenant.reload.email_monthly_limit).to eq(10_000)
  end
end
