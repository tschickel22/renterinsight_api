# frozen_string_literal: true

require 'rails_helper'

# Covers POST /api/v1/contacts/bulk_add_tags — the "select all matching" tagging
# path for the Contacts list (parity with leads). Accepts an explicit
# contact_ids batch OR the same filter #index uses.
RSpec.describe 'Api::V1::Contacts bulk_add_tags', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  def make_contact(attrs = {})
    Contact.create!({ company_id: company.id, first_name: 'A', last_name: 'B',
                      email: "c-#{SecureRandom.hex(4)}@x.com" }.merge(attrs))
  end

  def tags_on(contact)
    TagAssignment.where(entity_type: 'Contact', entity_id: contact.id).includes(:tag).map { |a| a.tag.name }
  end

  it 'creates a tag by name and applies it to the given contacts' do
    c1 = make_contact
    c2 = make_contact
    post '/api/v1/contacts/bulk_add_tags',
         params: { contact_ids: [c1.id, c2.id], tag_names: ['Newsletter'] }.to_json,
         headers: auth_headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['tagged_count']).to eq(2)
    expect(body['assignments_created']).to eq(2)
    expect(tags_on(c1)).to include('Newsletter')
    expect(tags_on(c2)).to include('Newsletter')
  end

  it 'is idempotent on re-tag' do
    c1 = make_contact
    2.times do
      post '/api/v1/contacts/bulk_add_tags',
           params: { contact_ids: [c1.id], tag_names: ['VIP'] }.to_json, headers: auth_headers
    end
    expect(JSON.parse(response.body)['assignments_created']).to eq(0)
    expect(TagAssignment.where(entity_type: 'Contact', entity_id: c1.id).count).to eq(1)
  end

  it 'tags every contact matching the filter (select all matching)' do
    mine = Array.new(3) { make_contact(owner_id: user.id) }
    other = make_contact(owner_id: nil)
    post '/api/v1/contacts/bulk_add_tags',
         params: { filter: { owner_id: user.id }, tag_names: ['Mine'] }.to_json, headers: auth_headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['tagged_count']).to eq(3)
    mine.each { |c| expect(tags_on(c)).to include('Mine') }
    expect(tags_on(other)).not_to include('Mine')
  end

  it 'reuses the company tag (creates no duplicate) for a company-scoped name' do
    existing = company.tags.create!(name: 'Existing', color: '#111', is_active: true, created_by: 'system')
    c1 = make_contact
    expect {
      post '/api/v1/contacts/bulk_add_tags',
           params: { contact_ids: [c1.id], tag_ids: [existing.id] }.to_json, headers: auth_headers
    }.not_to change { Tag.count }
    expect(tags_on(c1)).to eq(['Existing'])
  end

  it '400s when no tags are provided' do
    c1 = make_contact
    post '/api/v1/contacts/bulk_add_tags',
         params: { contact_ids: [c1.id] }.to_json, headers: auth_headers
    expect(response).to have_http_status(:bad_request)
  end

  it 'does not tag contacts from another company' do
    other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    foreign = Contact.create!(company_id: other_company.id, first_name: 'X', last_name: 'Y', email: 'f@x.com')
    post '/api/v1/contacts/bulk_add_tags',
         params: { contact_ids: [foreign.id], tag_names: ['Nope'] }.to_json, headers: auth_headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['tagged_count']).to eq(0)
    expect(tags_on(foreign)).to be_empty
  end
end
