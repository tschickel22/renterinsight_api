# frozen_string_literal: true

require 'rails_helper'

# A lead alert email drops the recipient on /crm/leads/:id with nothing selected.
# Asking them which of four rooftops that unfamiliar lead belongs to is a
# question they cannot answer, and picking wrong stranded them where the record
# was not. The record knows, so the app asks the server.
RSpec.describe 'Deep link context resolution', type: :request do
  # RBAC is exercised through its own suites; take skip_rbac?'s non-RBAC path.
  let(:company) { create(:company, use_rbac_system: false) }
  let(:other_company) { create(:company, use_rbac_system: false) }
  let(:location) { Location.create!(company: company, name: 'PC-Evangeline') }
  let(:user) do
    User.create!(email: "deeplink-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Hayden', last_name: 'Canter')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end
  let(:lead) { create(:lead, company: company, location_id: location.id) }

  describe 'GET /api/v1/deep_links/resolve' do
    it 'answers with the location the lead actually lives in' do
      get '/api/v1/deep_links/resolve', params: { type: 'lead', id: lead.id }, headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['locationId']).to eq(location.id)
      expect(body['locationName']).to eq('PC-Evangeline')
      expect(body['companyId']).to eq(company.id)
    end

    it 'refuses to resolve a record belonging to another company' do
      foreign_lead = create(:lead, company: other_company)

      get '/api/v1/deep_links/resolve', params: { type: 'lead', id: foreign_lead.id }, headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it 'rejects a type it does not know how to resolve' do
      get '/api/v1/deep_links/resolve', params: { type: 'invoices; drop', id: 1 }, headers: headers

      expect(response).to have_http_status(:bad_request)
    end

    it 'returns not found rather than an error for a missing record' do
      get '/api/v1/deep_links/resolve', params: { type: 'lead', id: 999_999_999 }, headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it 'reports a null location for a record that has none yet' do
      unplaced = create(:lead, company: company, location_id: nil)

      get '/api/v1/deep_links/resolve', params: { type: 'lead', id: unplaced.id }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['locationId']).to be_nil
    end

    it 'requires authentication' do
      get '/api/v1/deep_links/resolve', params: { type: 'lead', id: lead.id }

      expect(response).to have_http_status(:unauthorized)
    end

    # Every key here has to exist in `resources` or authorize_action! denies
    # every RBAC user and the feature quietly stops working for them.
    it 'maps every type to a permission resource that exists' do
      keys = Api::V1::DeepLinksController::RESOLVABLE_TYPES.values.map { |m| m[:resource] }.uniq

      keys.each do |key|
        expect(Resource.exists?(key: key)).to be(true), "resource key '#{key}' has no row in resources"
      end
    end

    it 'only maps models that carry a location_id' do
      Api::V1::DeepLinksController::RESOLVABLE_TYPES.each_value do |mapping|
        klass = mapping[:model].constantize
        expect(klass.column_names).to include('location_id'), "#{mapping[:model]} has no location_id"
      end
    end
  end
end
