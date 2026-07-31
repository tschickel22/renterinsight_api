# frozen_string_literal: true

require 'rails_helper'

# The AI panel calls usage + suggested on mount. When those answered "you don't
# have this module" with a 403, the global apiClient interceptor turned it into a
# "Permission Denied" toast on every page load for tenants without the module.
# Asking about your own entitlement is a status question, not a forbidden action.
RSpec.describe 'Report AI status endpoints without the AI module', type: :request do
  # RBAC is exercised elsewhere; take skip_rbac?'s non-RBAC path here.
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "no-ai-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'No', last_name: 'Ai')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  before do
    # Explicitly deny the module so the AI limit resolves to 0 (enabled: false).
    company.tenant_module_overrides.create!(module_key: 'management_ai_reports', is_enabled: false)
  end

  describe 'GET /api/v1/report-ai/usage' do
    it 'returns 200 rather than a 403 the UI would toast' do
      get '/api/v1/report-ai/usage', headers: headers

      expect(response).to have_http_status(:ok)
    end

    it 'reports the disabled state in the payload so the UI can gate itself' do
      get '/api/v1/report-ai/usage', headers: headers

      expect(JSON.parse(response.body).dig('usage', 'enabled')).to eq(false)
    end
  end

  describe 'GET /api/v1/report-ai/suggested' do
    it 'returns 200 rather than a 403 the UI would toast' do
      get '/api/v1/report-ai/suggested', headers: headers

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'endpoints that actually spend AI budget' do
    it 'still refuses to answer a question without the module' do
      post '/api/v1/report-ai/ask', params: { question: 'how many leads' }, headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'still refuses to classify without the module' do
      post '/api/v1/report-ai/classify', params: { question: 'how many leads' }, headers: headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
