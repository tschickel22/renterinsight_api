# frozen_string_literal: true

require 'rails_helper'

# Covers DELETE /api/v1/service-tickets/:id, specifically the guard against
# deleting a ticket that still has an active warranty claim, and the
# ?cascade=true escape hatch that soft-deletes a draft claim first.
RSpec.describe 'Api::V1 Service ticket destroy', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:manufacturer) { Manufacturer.create!(company_id: company.id, name: "Mfr-#{SecureRandom.hex(4)}", industry_type: 'manufactured_housing') }
  let(:ticket) { ServiceTicket.create!(company_id: company.id, title: 'Leaky roof', description: 'Water in the bedroom') }

  it 'destroys a ticket with no warranty claim' do
    delete "/api/v1/service-tickets/#{ticket.id}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(ServiceTicket.where(id: ticket.id)).to be_empty
  end

  context 'when the ticket has an active warranty claim' do
    before { ticket.mark_as_warranty!(manufacturer_id: manufacturer.id, marked_by: user.id) }

    it 'refuses deletion with 422 (no cascade)' do
      delete "/api/v1/service-tickets/#{ticket.id}", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body['errors'].join(' ')).to match(/warranty/i)
      expect(ServiceTicket.find(ticket.id)).to be_present
    end

    it 'cascades when ?cascade=true and the claim is still draft' do
      delete "/api/v1/service-tickets/#{ticket.id}?cascade=true", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(ServiceTicket.where(id: ticket.id)).to be_empty
      expect(WarrantyClaim.where(service_ticket_id: ticket.id)).to be_empty
    end

    it 'refuses cascade when the claim is no longer draft' do
      claim = WarrantyClaim.where(service_ticket_id: ticket.id, is_deleted: false).first
      claim.update!(status: 'submitted')

      delete "/api/v1/service-tickets/#{ticket.id}?cascade=true", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors'].first).to match(/submitted/i)
      expect(ServiceTicket.find(ticket.id)).to be_present
    end
  end
end
