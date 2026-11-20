# frozen_string_literal: true

require 'rails_helper'

# Files tab on CRM records (RecordFiles concern): accounts and contacts under
# /api/v1, leads and deals under /api/crm.
RSpec.describe 'Record files', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Tess', last_name: 'Upload',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:pdf) { Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4 test'), 'application/pdf', original_filename: 'NDA.pdf') }

  let(:account) { company.accounts.create!(name: 'Parkview') }
  let(:records) do
    {
      "/api/v1/accounts/#{account.id}" => account,
      "/api/v1/contacts/#{company.contacts.create!(first_name: 'Pat', account: account).id}" => nil,
      "/api/crm/leads/#{company.leads.create!(first_name: 'Joe', status: 'new').id}" => nil,
      "/api/crm/deals/#{company.deals.create!(name: 'Rollout', account: account, stage: 'prospecting', value: 0).id}" => nil
    }
  end

  it 'uploads, lists, links and deletes a file on every record type' do
    records.each_key do |base|
      post "#{base}/files", params: { files: [pdf] }, headers: headers
      expect(response).to have_http_status(:created), "#{base}: #{response.body}"
      created = JSON.parse(response.body)['files'].sole
      expect(created).to include('filename' => 'NDA.pdf', 'content_type' => 'application/pdf', 'added_by' => 'Tess Upload')

      get "#{base}/files", headers: headers
      expect(JSON.parse(response.body)['files'].map { |f| f['filename'] }).to eq(['NDA.pdf'])

      get "#{base}/files/#{created['id']}/download", headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['url']).to be_present

      delete "#{base}/files/#{created['id']}", headers: headers
      expect(response).to have_http_status(:no_content)
    end
  end

  it "does not reach another company's record" do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    theirs = other.leads.create!(first_name: 'Not', status: 'new')
    theirs.files.attach(io: StringIO.new('secret'), filename: 'secret.pdf', content_type: 'application/pdf')

    get "/api/crm/leads/#{theirs.id}/files", headers: headers
    expect(response).to have_http_status(:not_found)

    get "/api/crm/leads/#{theirs.id}/files/#{theirs.files_attachments.sole.id}/download", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "does not hand out a file attached to a different record of the same company" do
    mine = company.leads.create!(first_name: 'Mine', status: 'new')
    other_lead = company.leads.create!(first_name: 'Other', status: 'new')
    other_lead.files.attach(io: StringIO.new('x'), filename: 'x.pdf', content_type: 'application/pdf')

    get "/api/crm/leads/#{mine.id}/files/#{other_lead.files_attachments.sole.id}/download", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'refuses an upload with no file' do
    post "/api/v1/accounts/#{account.id}/files", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
