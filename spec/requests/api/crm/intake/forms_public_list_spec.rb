# frozen_string_literal: true

require 'rails_helper'

# The public inventory token rides in every shared listing URL. It used to
# unlock the full list of a dealer's active forms, configuration included, and
# the listing page's Share dialog showed that list to shoppers. The list is
# staff only; a public page asks for one form by id.
RSpec.describe 'Api::Crm::Intake::Forms public access', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@x.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:jwt) { JsonWebToken.encode(user_id: admin.id, company_id: company.id) }
  let!(:form) do
    IntakeForm.create!(company_id: company.id, name: 'test 4423', schema: [], is_active: true,
                       auto_create_lead: true, auto_create_activity: false)
  end
  let(:public_params) { { token: company.public_inventory_token, company_id: company.id } }

  it 'refuses the form list to a public token' do
    get '/api/crm/intake/forms', params: public_params

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include('test 4423')
  end

  describe 'a single form' do
    let(:notified) do
      User.create!(email: "n-#{SecureRandom.hex(4)}@x.com", first_name: 'N', last_name: 'N',
                   password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
    end
    let(:internal_keys) do
      %w[notified_user_id notifiedUserId field_mappings fieldMappings source_id sourceId
         location_id locationId submission_count company_id embedCode auto_create_lead]
    end

    before do
      form.update!(notified_user_id: notified.id, field_mappings: { 'email' => 'email' },
                   description: 'Tell us about you', thank_you_message: 'Thanks!',
                   schema: [{ 'key' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true }])
    end

    def expect_visitor_view(body)
      expect(body.keys & internal_keys).to be_empty
      expect(body).to include('name' => 'test 4423', 'description' => 'Tell us about you',
                              'thank_you_message' => 'Thanks!', 'publicId' => form.public_id)
      expect(body['fields'].first).to include('key' => 'email')
      expect(body['marketing_consent']).to include('enabled' => true)
    end

    it 'serves only the visitor view to a public token, for the embedded form' do
      get "/api/crm/intake/forms/#{form.id}", params: public_params

      expect(response).to have_http_status(:ok)
      expect_visitor_view(JSON.parse(response.body))
    end

    it 'serves only the visitor view on the public form link' do
      get "/api/f/#{form.public_id}"

      expect(response).to have_http_status(:ok)
      expect_visitor_view(JSON.parse(response.body))
    end

    it 'still serves the full configuration to signed-in staff' do
      get "/api/crm/intake/forms/#{form.id}", headers: { 'Authorization' => "Bearer #{jwt}" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include('notified_user_id' => notified.id)
    end
  end

  it 'still lists forms for signed-in staff' do
    get '/api/crm/intake/forms', headers: { 'Authorization' => "Bearer #{jwt}" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).map { |f| f['name'] }).to include('test 4423')
  end
end
