# frozen_string_literal: true

require 'rails_helper'

# Deals priced on line items carry their sales tax on the lines and never write
# deals.tax_amount (only the TrueBuild Deal Sheet does), so the Form 500's Sales Tax
# printed $0 on Coastal Breeze deal 659.
RSpec.describe 'Agreement merge fields: sales tax', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:buyer) { company.contacts.create!(first_name: 'Keia', last_name: 'Walker', email: 'k@example.com') }
  let(:deal) { company.deals.create!(name: 'Walker home', contact_id: buyer.id) }

  def tax_field
    get '/api/v1/agreement_merge_fields', params: { deal_id: deal.id }, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body['merge_fields'].values.flat_map { |g| g['fields'] }.find { |f| f['key'] == 'deal.tax_amount' }['value']
  end

  it 'adds up the tax on the line items' do
    deal.deal_products.create!(product_name: 'Home', quantity: 1, unit_price: 161_000, tax: 4830, total: 165_830, source_type: 'home')
    deal.deal_products.create!(product_name: 'Steps', quantity: 1, unit_price: 500, tax: 15, total: 515)

    expect(tax_field.to_f).to eq(4845.0)
  end

  it "uses the deal's own tax when the lines carry none (Deal Sheet deals)" do
    deal.update_columns(tax_amount: 2731.65)
    deal.deal_products.create!(product_name: 'Home', quantity: 1, unit_price: 60_000, tax: 0, total: 60_000)

    expect(tax_field.to_f).to eq(2731.65)
  end
end
