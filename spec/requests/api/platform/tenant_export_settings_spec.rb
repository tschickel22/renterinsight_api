# frozen_string_literal: true

require 'rails_helper'

# The per-tenant switch Tom flips to hand a specific tenant the JSON format.
# Deliberately platform-only: a tenant admin must not be able to grant it to
# themselves, which is why it sits outside RBAC.
RSpec.describe 'Api::Platform TenantExportSettings', type: :request do
  let(:tenant) { Company.create!(name: "Tenant #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:platform_admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: tenant.id, role: 'platform_admin')
  end
  let(:tenant_admin) do
    User.create!(email: "ta-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'A',
                 password: 'Pass1234!', company_id: tenant.id, role: 'company_admin')
  end

  def auth_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: tenant.id)}" }
  end

  it 'reports the tenant defaults with JSON withheld' do
    get "/api/platform/tenants/#{tenant.id}/export_settings", headers: auth_for(platform_admin)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['settings']['allow_json']).to be(false)
    expect(body['allowed_formats']).to contain_exactly('csv', 'xlsx')
  end

  it 'turns JSON on for one tenant without touching others' do
    other = Company.create!(name: "Other #{SecureRandom.hex(4)}", industry: 'manufactured_housing')

    patch "/api/platform/tenants/#{tenant.id}/export_settings",
          params: { allow_json: true }, headers: auth_for(platform_admin)

    expect(response).to have_http_status(:ok)
    expect(ImportExport::ExportPolicy.json_allowed?(tenant)).to be(true)
    expect(ImportExport::ExportPolicy.json_allowed?(other)).to be(false)
  end

  it 'updates the numeric limits' do
    patch "/api/platform/tenants/#{tenant.id}/export_settings",
          params: { daily_export_limit: 10, max_export_rows: 500, alert_row_threshold: 250 },
          headers: auth_for(platform_admin)

    expect(response).to have_http_status(:ok)
    settings = ImportExport::ExportPolicy.settings_for(tenant)
    expect(settings['daily_export_limit']).to eq(10)
    expect(settings['max_export_rows']).to eq(500)
    expect(settings['alert_row_threshold']).to eq(250)
  end

  it 'rejects a negative limit' do
    patch "/api/platform/tenants/#{tenant.id}/export_settings",
          params: { daily_export_limit: -1 }, headers: auth_for(platform_admin)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'refuses a tenant admin trying to grant it to themselves' do
    patch "/api/platform/tenants/#{tenant.id}/export_settings",
          params: { allow_json: true }, headers: auth_for(tenant_admin)

    expect(response).to have_http_status(:forbidden)
    expect(ImportExport::ExportPolicy.json_allowed?(tenant)).to be(false)
  end
end
