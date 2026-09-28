# frozen_string_literal: true

require 'rails_helper'

# Attachments on nurture email templates. Editing a template sends the new
# files as a multipart PATCH; the frontend used to POST to /templates/:id,
# which has no route, so the files were dropped.
RSpec.describe 'Api::Crm::Nurture template attachments', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'X-Company-ID' => company.id.to_s } }
  let(:pdf) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/test.pdf'), 'application/pdf') }

  def template_params
    { name: 'Welcome', template_type: 'email', subject: 'Hi', body: '<p>Hello</p>', is_active: 'true' }
  end

  it 'saves attachments sent with a new template' do
    post '/api/crm/nurture/templates', params: { template: template_params, attachments: [pdf] }, headers: headers

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)['attachments'].map { |a| a['filename'] }).to eq(['test.pdf'])
  end

  it 'adds attachments when an existing template is updated with PATCH' do
    template = company.templates.create!(template_params)

    patch "/api/crm/nurture/templates/#{template.id}",
          params: { template: template_params.merge(name: 'Welcome v2'), attachments: [pdf] }, headers: headers

    expect(response).to have_http_status(:ok)
    get '/api/crm/nurture/templates', headers: headers
    row = JSON.parse(response.body).find { |t| t['id'] == template.id }
    expect(row['name']).to eq('Welcome v2')
    expect(row['attachments'].map { |a| a['filename'] }).to eq(['test.pdf'])
  end

  it 'has no POST route for an existing template (what the old code called)' do
    template = company.templates.create!(template_params)

    post "/api/crm/nurture/templates/#{template.id}", params: { template: template_params, attachments: [pdf] }, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(template.reload.attachments).not_to be_attached
  end
end
