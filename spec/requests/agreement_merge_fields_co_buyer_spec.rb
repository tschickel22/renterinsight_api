# frozen_string_literal: true

require 'rails_helper'

# Two-buyer purchase agreements (Factory Direct's has Buyer 2 on nearly every
# page) fill Buyer 2 from the deal's co-applicant contact.
RSpec.describe 'Agreement merge fields: co-buyer', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:buyer) { company.contacts.create!(first_name: 'Jeretta', last_name: 'Smuts', email: 'j@example.com') }
  let(:co_buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smuts', email: 'pat@example.com', phone: '2605550100') }

  def fields_for(deal)
    get '/api/v1/agreement_merge_fields', params: { deal_id: deal.id }, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body['merge_fields'].values.flat_map { |g| g['fields'] }.to_h { |f| [f['key'], f['value']] }
  end

  it "offers the co-applicant as Buyer 2" do
    deal = company.deals.create!(name: 'Smuts home', contact_id: buyer.id, co_applicant_contact_id: co_buyer.id)

    fields = fields_for(deal)
    expect(fields['deal.co_buyer_name']).to eq('Pat Smuts')
    expect(fields['deal.co_buyer_email']).to eq('pat@example.com')
    expect(fields['deal.co_buyer_phone']).to eq('2605550100')
  end

  it 'leaves Buyer 2 empty on a one-buyer deal' do
    deal = company.deals.create!(name: 'Solo', contact_id: buyer.id)

    fields = fields_for(deal)
    expect(fields).to include('deal.co_buyer_name' => nil, 'deal.co_buyer_email' => nil)
  end
end
