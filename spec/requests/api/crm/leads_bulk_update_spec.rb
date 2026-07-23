# frozen_string_literal: true

require 'rails_helper'

# Covers POST /api/crm/leads/bulk_update — the "select all matching" path for the
# Bulk Edit modal (status and/or owner). Accepts an explicit lead_ids batch OR the
# same filter #index uses, and updates the whole matching set in one query.
RSpec.describe 'Api::Crm::Leads bulk_update', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  def make_lead(attrs = {})
    Lead.create!({ company_id: company.id, first_name: 'A', last_name: 'B',
                   email: "l-#{SecureRandom.hex(4)}@x.com", status: 'new' }.merge(attrs))
  end

  it 'updates status for an explicit selection' do
    l1 = make_lead
    l2 = make_lead
    post '/api/crm/leads/bulk_update',
         params: { lead_ids: [l1.id, l2.id], status: 'qualified' }.to_json, headers: auth_headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['updated_count']).to eq(2)
    expect(l1.reload.status).to eq('qualified')
    expect(l2.reload.status).to eq('qualified')
  end

  it 'updates status AND owner together across the whole filter' do
    matching = Array.new(3) { make_lead(owner_id: nil) }
    post '/api/crm/leads/bulk_update',
         params: { filter: { owner_id: 'unassigned' }, status: 'contacted', owner_id: rep.id }.to_json,
         headers: auth_headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['updated_count']).to eq(3)
    matching.each do |l|
      l.reload
      expect(l.status).to eq('contacted')
      expect(l.owner_id).to eq(rep.id)
    end
  end

  it 'rejects an owner from another company' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    foreign = User.create!(email: "f-#{SecureRandom.hex(4)}@x.com", first_name: 'F', last_name: 'C',
                           password: 'Pass1234!', company_id: other.id, role: 'sales_rep', status: 'active')
    l1 = make_lead
    post '/api/crm/leads/bulk_update',
         params: { lead_ids: [l1.id], owner_id: foreign.id }.to_json, headers: auth_headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(l1.reload.owner_id).to be_nil
  end

  it '400s when no updatable fields are provided' do
    l1 = make_lead
    post '/api/crm/leads/bulk_update',
         params: { lead_ids: [l1.id] }.to_json, headers: auth_headers
    expect(response).to have_http_status(:bad_request)
  end

  it '400s when neither lead_ids nor filter is provided' do
    post '/api/crm/leads/bulk_update',
         params: { status: 'qualified' }.to_json, headers: auth_headers
    expect(response).to have_http_status(:bad_request)
  end

  it 'will not update a lead from another company via explicit ids' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    foreign = Lead.create!(company_id: other.id, first_name: 'X', last_name: 'Y', email: 'f2@x.com', status: 'new')
    post '/api/crm/leads/bulk_update',
         params: { lead_ids: [foreign.id], status: 'qualified' }.to_json, headers: auth_headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['updated_count']).to eq(0)
    expect(foreign.reload.status).to eq('new')
  end
end
