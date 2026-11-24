# frozen_string_literal: true

require 'rails_helper'

# Two windows on one draft each auto-saved their own copy, and the last save put
# back what the other had changed (production agreement 94 lost its buyers'
# signature boxes). The builder now sends the edit number it loaded, and a save
# from a window holding an older copy is refused and told who saved.
RSpec.describe 'Agreement edits from two windows', type: :request do
  let(:company) { Company.create!(name: "Edit Co #{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Cedric', last_name: 'Calloway', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:agreement) { company.agreements.create!(title: 'Purchase Agreement', status: 'draft', prepared_by: user) }

  def body = JSON.parse(response.body)

  def save(title, version)
    patch "/api/v1/agreements/#{agreement.id}", params: { edit_version: version, agreement: { title: title } }.to_json, headers: headers
  end

  it 'counts each save and names who made it' do
    save('First', 0)
    expect(response).to have_http_status(:ok)
    expect(body['edit_version']).to eq(1)
    expect(agreement.reload.metadata['last_edited_by']['name']).to eq('Cedric Calloway')
  end

  it 'refuses a save from a window that loaded an older copy, and keeps the newer one' do
    save('From window A', 0)
    save('From window B', 0)

    expect(response).to have_http_status(:conflict)
    expect(body['code']).to eq('edited_elsewhere')
    expect(body['error']).to include('Cedric Calloway saved this agreement in another window')
    expect(body['edit_version']).to eq(1)
    expect(agreement.reload.title).to eq('From window A')
  end

  it 'still saves from an older builder that sends no edit number' do
    save('From window A', 0)
    patch "/api/v1/agreements/#{agreement.id}", params: { agreement: { title: 'Old builder' } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(agreement.reload.title).to eq('Old builder')
  end

  it 'does not let the browser set the edit number through metadata' do
    patch "/api/v1/agreements/#{agreement.id}", params: { agreement: { metadata: { edit_version: 99, left_off_signer_roles: [] } } }.to_json, headers: headers
    expect(agreement.reload.edit_version).to eq(1)
  end
end
