# frozen_string_literal: true

require 'rails_helper'

# This API read service_tickets.deleted_at and completed_date, which production has
# never had, so every call failed. Specs could not see it while schema.rb listed them.
RSpec.describe 'Api::Partner::V1 service tickets', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:creator) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:key) do
    ApiKey.new(company_id: company.id, name: 'partner', key: "ri_live_#{SecureRandom.hex(24)}",
               permissions: { 'service_tickets' => %w[read create update delete] },
               status: 'active', created_by_user_id: creator.id).tap { |k| k.save!(validate: false) }
  end
  let(:headers) { { 'Authorization' => "Bearer #{key.key}", 'Content-Type' => 'application/json' } }
  let!(:ticket) { company.service_tickets.create!(title: 'Leak', description: 'Roof leak') }
  let(:data) { JSON.parse(response.body)['data'] }

  it 'lists tickets' do
    get '/api/partner/v1/service-tickets', headers: headers
    expect(response).to have_http_status(:ok)
    expect(data.map { |t| t['id'] }).to contain_exactly(ticket.id)
  end

  it 'shows a ticket' do
    get "/api/partner/v1/service-tickets/#{ticket.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(data).to include('id' => ticket.id, 'description' => 'Roof leak')
  end

  it 'creates and updates a ticket' do
    post '/api/partner/v1/service-tickets', params: { title: 'New', description: 'D' }.to_json, headers: headers
    expect(response).to have_http_status(:created)

    id = data['id']
    patch "/api/partner/v1/service-tickets/#{id}", params: { title: 'Changed' }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(ServiceTicket.find(id).title).to eq('Changed')
  end

  it 'deletes a ticket' do
    delete "/api/partner/v1/service-tickets/#{ticket.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(data).to include('deleted' => true)
    expect(ServiceTicket.exists?(ticket.id)).to be(false)
  end

  it "cannot reach another company's ticket" do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'manufactured_housing')
    theirs = other.service_tickets.create!(title: 'Theirs', description: 'D')

    get "/api/partner/v1/service-tickets/#{theirs.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    delete "/api/partner/v1/service-tickets/#{theirs.id}", headers: headers
    expect(ServiceTicket.exists?(theirs.id)).to be(true)
  end
end
