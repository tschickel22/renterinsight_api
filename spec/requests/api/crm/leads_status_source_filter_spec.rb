# frozen_string_literal: true

require 'rails_helper'

# Status and source used to be filtered in the browser on the loaded page only,
# so the list total and "select all matching" counted every lead. They are now
# server-side filters shared by #index and the bulk actions.
RSpec.describe 'Api::Crm::Leads status and source filters', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:meta_list) { Source.create!(company_id: company.id, name: 'Meta dealer list', is_active: true) }
  let(:website)   { Source.create!(company_id: company.id, name: 'Website', is_active: true) }

  def make_lead(attrs = {})
    Lead.create!({ company_id: company.id, first_name: 'A', last_name: 'B',
                   email: "l-#{SecureRandom.hex(4)}@x.com", status: 'new' }.merge(attrs))
  end

  before do
    make_lead(source_id: meta_list.id)
    make_lead(source_id: meta_list.id, status: 'contacted')
    make_lead(source_id: website.id)
  end

  it 'totals only the leads from the picked source' do
    get '/api/crm/leads', params: { source_id: meta_list.id }, headers: auth_headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('meta', 'total')).to eq(2)
  end

  it 'totals only the leads with the picked status' do
    get '/api/crm/leads', params: { status: 'contacted' }, headers: auth_headers
    expect(JSON.parse(response.body).dig('meta', 'total')).to eq(1)
  end

  it "treats 'all' as no filter" do
    get '/api/crm/leads', params: { status: 'all', source_id: 'all' }, headers: auth_headers
    expect(JSON.parse(response.body).dig('meta', 'total')).to eq(3)
  end

  it 'bulk updates only the leads matching the source filter' do
    post '/api/crm/leads/bulk_update',
         params: { filter: { source_id: meta_list.id }, status: 'qualified' }.to_json, headers: auth_headers
    expect(JSON.parse(response.body)['updated_count']).to eq(2)
    expect(company.leads.where(source_id: website.id).pluck(:status)).to eq(['new'])
  end
end
