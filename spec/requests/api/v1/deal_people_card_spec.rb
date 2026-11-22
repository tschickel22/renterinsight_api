# frozen_string_literal: true

require 'rails_helper'

# The deal's people card endpoints (Tom, 2026-11-22): never blank when the deal
# knows its Buyer, suggests account contacts, adds people to a deal with no
# account, and says why when it refuses.
RSpec.describe 'Deal people card', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:account) { company.accounts.create!(name: 'Smuts') }
  let(:buyer) { company.contacts.create!(first_name: 'Jeretta', last_name: 'Smuts', account: account) }
  let(:spouse) { company.contacts.create!(first_name: 'Pat', last_name: 'Smuts', account: account) }

  def body = response.parsed_body

  it 'shows the Buyer on an older deal whose card was empty' do
    deal = company.deals.create!(name: 'D', account: account, contact_id: buyer.id)
    deal.entity_buyers.update_all(is_deleted: true)

    get "/api/v1/deals/#{deal.id}/buyers", headers: headers
    expect(response).to have_http_status(:ok)
    expect(body.map { |b| [b['contact_id'], b['role'], b['role_label']] }).to eq([[buyer.id, 'buyer', 'Buyer']])
  end

  it 'suggests account contacts who are not on the deal' do
    deal = company.deals.create!(name: 'D', account: account, contact_id: buyer.id)
    spouse

    get "/api/v1/deals/#{deal.id}/buyers/suggestions", headers: headers
    expect(body.map { |c| c['id'] }).to eq([spouse.id])
  end

  it 'adds a suggested person as Co-Buyer, which the Deal Sheet then reads' do
    deal = company.deals.create!(name: 'D', account: account, contact_id: buyer.id)

    post "/api/v1/deals/#{deal.id}/buyers", params: { contact_id: spouse.id }, headers: headers
    expect(response).to have_http_status(:created)
    expect(body['role']).to eq('co_buyer')
    expect(deal.reload.co_applicant_contact_id).to eq(spouse.id)
  end

  it 'adds a new person to a deal with no account and gives the deal a household account' do
    loose = company.contacts.create!(first_name: 'Lee', last_name: 'Ray')
    deal = company.deals.create!(name: 'D', contact_id: loose.id)

    post "/api/v1/deals/#{deal.id}/buyers",
         params: { role: 'guarantor', contact: { first_name: 'Mo', last_name: 'Ray', email: 'mo@example.com' } },
         headers: headers
    expect(response).to have_http_status(:created)
    deal.reload
    expect(deal.account).to be_present
    expect(deal.account.name).to eq('Lee Ray')
    expect(loose.reload.account_id).to eq(deal.account_id)
    expect(deal.entity_buyers.active.ordered.map { |e| [e.contact.first_name, e.role] }).to eq([%w[Lee buyer], %w[Mo guarantor]])
  end

  it 'refuses someone from another account and says why' do
    deal = company.deals.create!(name: 'D', account: account, contact_id: buyer.id)
    other = company.contacts.create!(first_name: 'Al', account: company.accounts.create!(name: 'Other'))

    post "/api/v1/deals/#{deal.id}/buyers", params: { contact_id: other.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['errors'].first).to include('different account')
  end

  it 'keeps a Buyer on a deal that has no account' do
    loose = company.contacts.create!(first_name: 'Lee')
    deal = company.deals.create!(name: 'D', contact_id: loose.id)
    row = deal.entity_buyers.active.first

    delete "/api/v1/deals/#{deal.id}/buyers/#{row.id}", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['errors'].first).to include('needs a Buyer')
  end
end

RSpec.describe 'Account deal people badges', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:account) { company.accounts.create!(name: 'Smuts') }
  let(:buyer) { company.contacts.create!(first_name: 'Jeretta', account: account) }
  let(:spouse) { company.contacts.create!(first_name: 'Pat', account: account) }

  it 'lists people on open deals only, reading the columns when the card is empty' do
    open_deal = company.deals.create!(name: 'Smuts home', account: account, contact_id: buyer.id, co_applicant_contact_id: spouse.id)
    open_deal.entity_buyers.update_all(is_deleted: true) # an older deal
    won = company.deals.create!(name: 'Old home', account: account, contact_id: buyer.id)
    won.update_column(:stage, company.won_stage_keys.first) if company.respond_to?(:won_stage_keys)

    get "/api/v1/accounts/#{account.id}/deal_people", headers: headers
    expect(response).to have_http_status(:ok)
    rows = response.parsed_body.map { |r| [r['contact_id'], r['role_label'], r['deal_name']] }
    expect(rows).to contain_exactly([buyer.id, 'Buyer', 'Smuts home'], [spouse.id, 'Co-Buyer', 'Smuts home'])
  end
end
