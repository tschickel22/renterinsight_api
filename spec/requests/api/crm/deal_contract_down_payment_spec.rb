# frozen_string_literal: true

require 'rails_helper'

# The deposit and the down payment on the contract are two separate amounts.
RSpec.describe 'Deal down payment', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Walker', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Walker', contact_id: buyer.id, down_payment: 1000) }

  it 'saves the down payment without touching the deposit' do
    patch "/api/crm/deals/#{deal.id}", headers: headers, params: { deal: { contract_down_payment: 8000 } }.to_json

    expect(response).to have_http_status(:ok)
    expect(deal.reload.contract_down_payment).to eq(8000)
    expect(deal.down_payment).to eq(1000)
  end

  it 'leaves the down payment empty when only a deposit was taken' do
    get "/api/crm/deals/#{deal.id}", headers: headers

    payload = JSON.parse(response.body)
    payload = payload['deal'] || payload
    expect(payload['contractDownPayment']).to be_nil
    expect(payload['downPayment'].to_f).to eq(1000)
  end

  it 'does not point the Form 500 at the deposit' do
    script = Rails.root.join('script/agreement_templates/form500_ms.rb').read
    expect(script).to include("merge_from: 'deal.contract_down_payment'")
    expect(script).not_to include("merge_from: 'deal.down_payment'")
  end
end
