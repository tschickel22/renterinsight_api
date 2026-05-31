# frozen_string_literal: true

require 'rails_helper'

# Enhancement 6 API surface: deal_desk_writeback_mode is exposed/persisted through the
# existing operational company-settings endpoints, written to its OWN top-level Setting key
# (the key the Company model reader uses) — never inside the operational_settings hash.
RSpec.describe 'Api::V1 company_settings deal_desk_writeback_mode', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@ex.com", first_name: 'A', last_name: 'D',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: admin.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  describe 'GET /api/v1/company_settings/operational' do
    it 'returns deal_desk_writeback_mode (default on_close)' do
      get '/api/v1/company_settings/operational', headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['deal_desk_writeback_mode']).to eq('on_close')
    end
  end

  describe 'PATCH /api/v1/company_settings/operational' do
    it 'persists a valid mode to the TOP-LEVEL key; the model reader reflects it' do
      patch '/api/v1/company_settings/operational',
            params: { deal_desk_writeback_mode: 'on_apply' }.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['deal_desk_writeback_mode']).to eq('on_apply')

      # Written to the dedicated top-level Setting key the model reads...
      expect(Setting.get('Company', company.id, 'deal_desk_writeback_mode')).to eq('on_apply')
      expect(company.reload.deal_desk_writeback_mode).to eq('on_apply')
      # ...and NOT nested inside the operational_settings hash.
      expect((Setting.get('Company', company.id, 'operational_settings') || {})).not_to have_key('deal_desk_writeback_mode')
    end

    it 'rejects an out-of-range value with 422' do
      patch '/api/v1/company_settings/operational',
            params: { deal_desk_writeback_mode: 'whenever' }.to_json, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors'].join).to match(/deal_desk_writeback_mode/)
      # The bad value must not have been written.
      expect(Setting.get('Company', company.id, 'deal_desk_writeback_mode')).to be_blank
    end

    it 'leaves the mode untouched when the param is absent' do
      Setting.set('Company', company.id, 'deal_desk_writeback_mode', 'on_apply')
      patch '/api/v1/company_settings/operational',
            params: { operational_settings: { timezone: 'America/Denver' } }.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(company.reload.deal_desk_writeback_mode).to eq('on_apply')
    end
  end

  describe 'RBAC gating (company_settings resource)' do
    it 'denies a user without company_settings permission' do
      company.update!(use_rbac_system: true)
      rep = company.users.create!(email: "r-#{SecureRandom.hex(3)}@ex.com", first_name: 'R', last_name: 'P',
                                  password: 'Pass1234!', role: 'user')
      rep_token = JsonWebToken.encode(user_id: rep.id, company_id: company.id)
      rep_headers = { 'Authorization' => "Bearer #{rep_token}", 'Content-Type' => 'application/json' }

      get '/api/v1/company_settings/operational', headers: rep_headers
      expect(response).to have_http_status(:forbidden)

      patch '/api/v1/company_settings/operational',
            params: { deal_desk_writeback_mode: 'on_apply' }.to_json, headers: rep_headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
