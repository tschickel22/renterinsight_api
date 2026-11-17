# frozen_string_literal: true

require 'rails_helper'

# A deal's Documents tab: staff-only files filed on the deal, and files shared
# with the buyer (owned by the deal's contact, related to the deal). Both roll
# up into the account's Documents summary.
RSpec.describe 'Api::Admin::Documents on a deal', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}") }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'S',
                        password: 'Pass1234!', company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let!(:account) { company.accounts.create!(name: 'Diaz Family') }
  let!(:contact) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz', email: "a-#{SecureRandom.hex(3)}@example.com", account: account) }
  let!(:deal) { company.deals.create!(location: location, name: 'Diaz home', account: account, contact: contact, stage: 'negotiation') }
  let(:pdf) { Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4 test'), 'application/pdf', original_filename: 'contract.pdf') }

  def body = JSON.parse(response.body)

  def upload(share:, deal_id: deal.id)
    post '/api/admin/documents', headers: headers,
                                 params: { deal_id: deal_id, file: pdf, title: 'Purchase agreement', category: 'contract', share_with_buyer: share }
  end

  it 'files a staff-only document on the deal, out of the buyer portal' do
    upload(share: false)
    expect(response).to have_http_status(:created), response.body
    doc = PortalDocument.find(body.dig('document', 'id'))
    expect(doc).to have_attributes(owner: deal, related_to: deal)
    expect(body['document']).to include('staff_only' => true, 'deal_id' => deal.id)
    expect(PortalDocument.by_owner(contact)).to be_empty
  end

  it 'shares a document with the buyer through the deal contact' do
    expect(PortalPushService).to receive(:new_document)
    upload(share: true)
    expect(response).to have_http_status(:created), response.body
    doc = PortalDocument.find(body.dig('document', 'id'))
    expect(doc).to have_attributes(owner: contact, related_to: deal)
    expect(body['document']).to include('buyer_id' => contact.id, 'deal_id' => deal.id)
  end

  it 'lists both on the deal and rolls them up into the account' do
    upload(share: false)
    upload(share: true)
    ids = PortalDocument.where(related_to: deal).pluck(:id)

    get '/api/admin/documents', params: { deal_id: deal.id }, headers: headers
    expect(body['documents'].map { |d| d['id'] }).to match_array(ids)

    get '/api/admin/documents', params: { account_id: account.id, per_page: 200 }, headers: headers
    expect(body['documents'].map { |d| d['id'] }).to include(*ids)
  end

  it 'refuses another company\'s deal' do
    other_deal = other_company.deals.create!(location: other_company.locations.create!(name: 'X'), name: 'Theirs',
                                             account: other_company.accounts.create!(name: 'T'), stage: 'negotiation')
    upload(share: false, deal_id: other_deal.id)
    expect(response).to have_http_status(:not_found)
  end
end
