# frozen_string_literal: true

require 'rails_helper'

# Covers the two service-ticket additions:
#   1. category-scoped notes (customer vs technician streams) on the generic
#      /api/v1/notes endpoints
#   2. the factory_po field on service tickets
RSpec.describe 'Api::V1 Service ticket notes (category) + factory_po', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:ticket) { ServiceTicket.create!(company_id: company.id, title: 'Leaky roof', description: 'Water in the bedroom') }

  describe 'category-scoped notes' do
    it 'creates notes under distinct categories and filters by category on read' do
      post '/api/v1/notes',
           params: { note: { content: 'Visible to customer', entity_type: 'service_ticket', entity_id: ticket.id.to_s, category: 'customer' } },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['category']).to eq('customer')

      post '/api/v1/notes',
           params: { note: { content: 'Internal only', entity_type: 'service_ticket', entity_id: ticket.id.to_s, category: 'technician' } },
           headers: headers
      expect(response).to have_http_status(:created)

      get "/api/v1/notes?entity_type=service_ticket&entity_id=#{ticket.id}&category=customer", headers: headers
      expect(response).to have_http_status(:ok)
      notes = JSON.parse(response.body)['notes']
      expect(notes.map { |n| n['content'] }).to eq(['Visible to customer'])
      expect(notes.map { |n| n['category'] }).to all(eq('customer'))
    end

    it 'stamps the author on a created note' do
      post '/api/v1/notes',
           params: { note: { content: 'Hi', entity_type: 'service_ticket', entity_id: ticket.id.to_s, category: 'customer' } },
           headers: headers
      body = JSON.parse(response.body)
      expect(body['createdBy']).to eq(user.id)
      expect(body['createdByName']).to be_present
      expect(body['authorType']).to eq('staff')
    end
  end

  describe 'factory_po' do
    it 'persists and returns factory_po on update' do
      patch "/api/v1/service-tickets/#{ticket.id}",
            params: { service_ticket: { factory_po: 'PO-12345' } },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('data', 'factoryPo')).to eq('PO-12345')
      expect(ticket.reload.factory_po).to eq('PO-12345')
    end
  end
end
