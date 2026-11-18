# frozen_string_literal: true

require 'rails_helper'

# Purchase agreements and closing packages fill these from the linked deal, and a
# box the preparer started can still be corrected by the buyer at signing.
RSpec.describe 'Agreement merge fields: closing package', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:buyer) { company.contacts.create!(first_name: 'Jeretta', last_name: 'Smuts', email: 'j@example.com') }

  def fields_for(params)
    get '/api/v1/agreement_merge_fields', params: params, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body['merge_fields'].values.flat_map { |g| g['fields'] }.to_h { |f| [f['key'], f['value']] }
  end

  it 'gives the lender and the delivery address in the forms the package prints' do
    deal = company.deals.create!(name: 'Smuts home', contact_id: buyer.id, lender_name: '21st Mortgage',
                                 delivery_street: '11 Road 739', delivery_city: 'Columbus', delivery_state: 'MS', delivery_zip: '39705')

    expect(fields_for(deal_id: deal.id)).to include(
      'deal.lender_name' => '21st Mortgage',
      'deal.delivery_city_state_zip' => 'Columbus, MS 39705',
      'deal.delivery_full_address' => '11 Road 739, Columbus, MS 39705'
    )
  end

  it 'names the contact as buyer when no deal is linked' do
    expect(fields_for(contact_id: buyer.id)['deal.buyer_names']).to eq('Jeretta Smuts')
  end

  it "lets the buyer's answer win over the value the preparer started" do
    agreement = company.agreements.new(merge_field_values: { 'custom.cbh_lender' => 'Buyer Bank' },
                                       custom_field_values: { 'cbh_lender' => 'Preparer Bank', 'cbh_date' => '11/18/2026' })

    values = AgreementPdfService.new(agreement).send(:build_values_map)
    expect(values['custom.cbh_lender']).to eq('Buyer Bank')
    expect(values['custom.cbh_date']).to eq('11/18/2026')
  end
end
