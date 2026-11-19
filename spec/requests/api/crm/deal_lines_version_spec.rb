# frozen_string_literal: true

require 'rails_helper'

# Two people with the same deal open: an out-of-date page must not put its old
# lines over what the other person just saved.
RSpec.describe 'Deal lines version', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Walker', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Walker', contact_id: buyer.id) }
  let(:products_path) { "/api/crm/deals/#{deal.id}/products" }

  def body = JSON.parse(response.body)
  def line(tax) = { product_name: 'Home', quantity: 1, unit_price: 161_000, cost: 119_659, tax: tax, notes: 'category:home, source:home' }

  def version
    get products_path, headers: headers
    body.fetch('lines_version')
  end

  def save(tax, lines_version: nil)
    params = { products: [line(tax)], replace: true }
    params[:lines_version] = lines_version if lines_version
    post "#{products_path}/bulk_create", headers: headers, params: params.to_json
  end

  before do
    save(0)
    expect(response).to have_http_status(:created)
  end

  it 'saves from the current copy and hands back the new version' do
    save(4830, lines_version: version)
    expect(response).to have_http_status(:created)
    expect(deal.deal_products.reload.sole.tax).to eq(4830)
    expect(body['lines_version']).to eq(version)
  end

  it 'refuses a page holding an older copy and keeps the newer lines' do
    stale = version
    save(4830, lines_version: stale)
    save(0, lines_version: stale)
    expect(response).to have_http_status(:conflict)
    expect(body['code']).to eq('deal_changed')
    expect(deal.deal_products.reload.sole.tax).to eq(4830)
  end

  it 'treats an identical save as no change, though the lines are recreated' do
    before_save = version
    save(0)
    expect(version).to eq(before_save)
  end

  it 'sees a deposit someone else entered' do
    before_deposit = version
    deal.update!(down_payment: 5000)
    expect(version).not_to eq(before_deposit)
  end

  it 'still saves for a page that sends no version' do
    version
    save(4830)
    expect(response).to have_http_status(:created)
  end
end
