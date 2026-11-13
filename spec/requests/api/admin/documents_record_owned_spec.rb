# frozen_string_literal: true

require 'rails_helper'

# The GoHighLevel loader files deal paperwork on the Account (or the Lead when
# there is no account yet). Every screen used to ask only for Contact-owned
# documents, so 87 Easy Homesource files sat on production unseen. These are
# staff-only: the buyer portal keeps reading Contact-owned documents.
RSpec.describe 'Api::Admin::Documents account and lead documents', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}") }

  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'Schickel',
                        password: 'Pass1234!', company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def doc_for(owner, name)
    doc = PortalDocument.new(owner: owner, document_name: name, category: 'contract', uploaded_by: 'staff')
    doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: name, content_type: 'application/pdf')
    doc.save!
    doc
  end

  let!(:account) { company.accounts.create!(name: 'Alexander Franco') }
  let!(:lead) { company.leads.create!(first_name: 'Hugo', last_name: 'Galindo', email: "h-#{SecureRandom.hex(3)}@example.com") }
  let!(:contact) { company.contacts.create!(first_name: 'Ann', last_name: 'Buyer', email: "a-#{SecureRandom.hex(3)}@example.com") }
  let!(:account_doc) { doc_for(account, 'Franco contract.pdf') }
  let!(:lead_doc) { doc_for(lead, 'Quote Galindo.pdf') }
  let!(:contact_doc) { doc_for(contact, 'Buyer upload.pdf') }
  let!(:foreign_doc) { doc_for(other_company.accounts.create!(name: 'Elsewhere'), 'Not yours.pdf') }

  it 'lists documents filed on an account, marked staff only' do
    get '/api/admin/documents', params: { account_id: account.id }, headers: headers

    docs = JSON.parse(response.body)['documents']
    expect(docs.map { |d| d['id'] }).to eq([account_doc.id])
    expect(docs.first).to include('buyer_name' => 'Alexander Franco', 'owner_type' => 'Account', 'staff_only' => true)
  end

  it 'lists documents filed on a lead' do
    get '/api/admin/documents', params: { lead_id: lead.id }, headers: headers

    expect(JSON.parse(response.body)['documents'].map { |d| d['id'] }).to eq([lead_doc.id])
  end

  it 'includes them in the company-wide list but never another company\'s' do
    get '/api/admin/documents', headers: headers

    ids = JSON.parse(response.body)['documents'].map { |d| d['id'] }
    expect(ids).to contain_exactly(account_doc.id, lead_doc.id, contact_doc.id)
  end

  it 'keeps buyer_id to contacts even when an account shares the number' do
    get '/api/admin/documents', params: { buyer_id: account.id }, headers: headers

    ids = JSON.parse(response.body)['documents'].map { |d| d['id'] }
    expect(ids).not_to include(account_doc.id)
  end

  it 'downloads an account document' do
    get "/api/admin/documents/#{account_doc.id}/download", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('%PDF-1.4')
  end

  it 'does not download another company\'s account document' do
    get "/api/admin/documents/#{foreign_doc.id}/download", headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
