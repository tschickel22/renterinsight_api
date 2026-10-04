# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Admin::TrueviewTransfer', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def headers_for(role)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S',
                        password: 'Pass1234!', company_id: company.id, role: role)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  it 'exports a page and imports it back with nested fields intact, for platform admins only' do
    allow(Truebuild::DrawingTransfer).to receive(:rehost) { |url| url }
    TruebuildRender.create!(source_url: 'https://p/1.jpg', purpose: 'layer', status: 'done', selection_key: 'k', model_key: 'nb2-lite',
                            provider: 'gemini', model: 'lite', prompt: 'p', selection: [{ 'surface' => 'Siding', 'value' => 'Clay' }],
                            usage: { 'mask_version' => 21, 'check' => { 'score' => 5 } }, layer_url: 'https://b/l.webp')
    admin = headers_for('platform_admin')
    get '/api/admin/trueview_transfer', params: { kind: 'renders' }, headers: admin
    rows = JSON.parse(response.body)['rows']
    TruebuildRender.delete_all

    post '/api/admin/trueview_transfer', params: { kind: 'renders', rows: rows }.to_json, headers: admin
    expect(JSON.parse(response.body)).to include('created' => 1, 'skipped' => [])
    expect(TruebuildRender.sole).to have_attributes(selection: [{ 'surface' => 'Siding', 'value' => 'Clay' }])
    expect(TruebuildRender.sole.usage).to include('mask_version' => 21, 'check' => { 'score' => 5 })

    get '/api/admin/trueview_transfer', params: { kind: 'renders' }, headers: headers_for('admin')
    expect(response).to have_http_status(:forbidden)
  end
end
