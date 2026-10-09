# frozen_string_literal: true

require 'rails_helper'

# The Deal Sheet's sections 4 (Buyer and site) and 5 (Contract): what the deal
# already holds is filled in, the contract's own details are saved on the
# deal, choices come from the lists, and the ready-to-send check names what is
# missing for a cash, finance or combined sale.
RSpec.describe 'Deal sale details', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com', phone: '260-555-0100', street: '1 Main St', city: 'Auburn', state: 'IN', zip: '46706') }
  let(:co_buyer) { company.contacts.create!(first_name: 'Sam', last_name: 'Smith', email: 'sam@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id, co_applicant_contact_id: co_buyer.id, delivery_street: '9 Farm Rd', delivery_city: 'Garrett', delivery_state: 'IN', delivery_zip: '46738') }
  let(:path) { "/api/v1/deals/#{deal.id}/sale_details" }

  def body = JSON.parse(response.body)

  it 'fills in what the deal holds and saves the contract details' do
    get path, headers: headers
    expect(body['filled']['buyer_1']).to include('name' => 'Pat Smith', 'email' => 'pat@example.com', 'address' => '1 Main St, Auburn IN 46706')
    expect(body['filled']['buyer_2']).to include('name' => 'Sam Smith')
    expect(body['filled']['delivery']).to include('street' => '9 Farm Rd', 'city' => 'Garrett')
    expect(body['choices']['contingency']).to include('Subject to financing approval')
    expect(body['missing']).to contain_exactly('Site ownership', 'Contingency', 'Cash or finance')

    patch path, headers: headers, params: { site_ownership: 'Buyer owns the land', county: 'DeKalb', contingency: 'Subject to financing approval',
                                            contingency_deadline: '2026-11-15', payment_type: 'finance', loan_type: 'Land-home (real property)' }.to_json
    expect(response).to have_http_status(:ok)
    expect(body['values']).to include('site_ownership' => 'Buyer owns the land', 'county' => 'DeKalb', 'contingency_deadline' => '2026-11-15')
    expect(deal.reload.payment_type).to eq('finance')
    expect(body['missing']).to eq(['Lender'])

    lender = company.lenders.create!(name: '21st Mortgage Corporation')
    patch path, headers: headers, params: { lender_id: lender.id }.to_json
    expect(deal.reload.lender_name).to eq('21st Mortgage Corporation')
    expect(body['missing']).to eq([])

    patch path, headers: headers, params: { payment_type: 'cash_and_finance' }.to_json
    expect(body['missing']).to eq(['Payment method']) # a combined sale takes both addenda
  end

  it 'refuses a value outside the choices, a bad date, and another dealer' do
    patch path, headers: headers, params: { contingency: 'Whenever' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    patch path, headers: headers, params: { contingency_deadline: 'soon' }.to_json
    expect(body['error']).to include('needs a date')

    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    theirs = other.lenders.create!(name: 'Not yours')
    patch path, headers: headers, params: { lender_id: theirs.id }.to_json
    expect(body['error']).to include('not one of yours')
  end
end
