# frozen_string_literal: true

require 'rails_helper'

# A portal (customer) user can reply to the customer-facing note thread on a
# ticket they own. The reply is stored as a category="customer" Note, attributed
# to the buyer, and surfaces in both the portal and staff views.
RSpec.describe 'Api::Portal service ticket note replies', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:account) { Account.create!(company: company, name: 'Buyer Co', status: 'active') }
  let(:buyer_access) do
    BuyerPortalAccess.create!(buyer: account, company_id: company.id,
                              email: "buyer-#{SecureRandom.hex(3)}@example.com",
                              password: 'Password123!', password_confirmation: 'Password123!')
  end
  let(:token) { JsonWebToken.encode(buyer_portal_access_id: buyer_access.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:ticket) do
    ServiceTicket.create!(company_id: company.id, account_id: account.id,
                          title: 'Leaky roof', description: 'Water', portal_visible: true)
  end

  it 'creates a customer-category note attributed to the buyer' do
    post "/api/portal/service-tickets/#{ticket.id}/notes",
         params: { note: { content: 'When can you come out?' } }, headers: headers

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body.dig('data', 'content')).to eq('When can you come out?')
    expect(body.dig('data', 'authorType')).to eq('customer')

    note = Note.for_entity('service_ticket', ticket.id.to_s).where(category: 'customer').last
    expect(note.content).to eq('When can you come out?')
    expect(note.created_by_name).to eq('Buyer Co')
    expect(note.author_type).to eq('customer')
  end

  it 'rejects blank content' do
    post "/api/portal/service-tickets/#{ticket.id}/notes",
         params: { note: { content: '' } }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'does not allow replying to a ticket the buyer does not own' do
    other = ServiceTicket.create!(company_id: company.id, title: 'Other', description: 'x', portal_visible: true)
    post "/api/portal/service-tickets/#{other.id}/notes",
         params: { note: { content: 'hi' } }, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
