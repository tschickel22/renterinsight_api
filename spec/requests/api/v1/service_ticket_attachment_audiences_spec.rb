# frozen_string_literal: true

require 'rails_helper'

# Per-file audience tagging on service ticket attachments:
#   - staff tag a file customer-visible / manufacturer-visible
#   - manufacturer-tagged files are copied onto the warranty claim
#   - the buyer portal only shows customer-visible files
RSpec.describe 'Api service ticket attachment audiences', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let(:ticket) do
    ServiceTicket.create!(company_id: company.id, title: 'Leaky roof', description: 'Water')
  end

  def attach_file(ticket, name)
    ticket.attachments.attach(io: StringIO.new("data-#{name}"), filename: name, content_type: 'image/png')
    ticket.attachments.reload.find { |a| a.filename.to_s == name }
  end

  describe 'tagging endpoint' do
    it 'sets and serializes audience flags' do
      att = attach_file(ticket, 'photo.png')

      patch "/api/v1/service-tickets/#{ticket.id}/attachments/#{att.id}/audience",
            params: { visible_to_manufacturer: true }, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)['data']
      expect(data['visibleToManufacturer']).to eq(true)
      expect(data['visibleToCustomer']).to eq(false)
      expect(AttachmentAudience.find_by(active_storage_attachment_id: att.id).visible_to_manufacturer).to be(true)
    end

    it '404s for an attachment that does not belong to the ticket' do
      patch "/api/v1/service-tickets/#{ticket.id}/attachments/999999/audience",
            params: { visible_to_customer: true }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'warranty claim copy' do
    # NOTE: Manufacturer.create! is broken in this schema (its normalize_fields
    # callback references columns that don't exist), so insert the row directly to
    # bypass callbacks. Unrelated to the feature under test.
    let(:manufacturer) do
      Manufacturer.insert!({ name: 'Acme Homes', industry_type: 'manufactured_housing', active: true,
                             created_at: Time.current, updated_at: Time.current })
      Manufacturer.order(:id).last
    end

    let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }

    before do
      ticket.update!(
        location_id: location.id,
        parts: [{ 'partNumber' => 'P1', 'description' => 'Shingle', 'quantity' => 1, 'unitCost' => 100, 'total' => 100 }],
        line_item_billing: [{ 'index' => 0, 'type' => 'part', 'billing_type' => 'warranty', 'manufacturer_id' => manufacturer.id }]
      )
    end

    it 'copies only manufacturer-tagged files onto the generated claim' do
      mfr_file = attach_file(ticket, 'manufacturer.png')
      attach_file(ticket, 'internal.png') # left untagged → internal only

      patch "/api/v1/service-tickets/#{ticket.id}/attachments/#{mfr_file.id}/audience",
            params: { visible_to_manufacturer: true }, headers: headers
      expect(response).to have_http_status(:ok)

      post "/api/v1/service-tickets/#{ticket.id}/generate-warranty-claim",
           params: { manufacturer_id: manufacturer.id, notes_to_manufacturer: 'please review' }, headers: headers

      expect(response).to have_http_status(:created)
      claim = WarrantyClaim.find(JSON.parse(response.body).dig('claim', 'id'))
      expect(claim.attachments.count).to eq(1)
      expect(claim.attachments.first.filename.to_s).to eq('manufacturer.png')
    end
  end

  describe 'buyer portal filtering' do
    let(:account) { Account.create!(company: company, name: 'Buyer Co', status: 'active') }
    let(:buyer_access) do
      BuyerPortalAccess.create!(buyer: account, company_id: company.id,
                                email: "buyer-#{SecureRandom.hex(3)}@example.com",
                                password: 'Password123!', password_confirmation: 'Password123!')
    end
    let(:portal_headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)}" } }
    let(:portal_ticket) do
      ServiceTicket.create!(company_id: company.id, account_id: account.id,
                            title: 'Roof', description: 'Water', portal_visible: true)
    end

    it 'returns only customer-visible attachments to the portal' do
      cust_file = attach_file(portal_ticket, 'for-customer.png')
      mfr_file  = attach_file(portal_ticket, 'for-manufacturer.png')

      AttachmentAudience.create!(active_storage_attachment_id: cust_file.id, visible_to_customer: true)
      AttachmentAudience.create!(active_storage_attachment_id: mfr_file.id, visible_to_manufacturer: true)

      get "/api/portal/service-tickets/#{portal_ticket.id}", headers: portal_headers

      expect(response).to have_http_status(:ok)
      filenames = JSON.parse(response.body).dig('data', 'attachments').map { |a| a['filename'] }
      expect(filenames).to contain_exactly('for-customer.png')
    end
  end
end
