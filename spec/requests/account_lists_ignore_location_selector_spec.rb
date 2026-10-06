# frozen_string_literal: true

require 'rails_helper'

# An account's page listed no deals or contacts when the location selector
# was on another lot (Jennifer Williams' records are all at Aurora; the rep
# was on Denver). One account's lists ignore the selector; RBAC still applies.
RSpec.describe 'Account deal and contact lists', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'UTC') }
  let(:aurora) { company.locations.create!(name: 'Aurora', timezone: 'UTC') }
  let(:account) { company.accounts.create!(name: 'Jennifer Williams', location_id: aurora.id) }
  let!(:contact) { company.contacts.create!(first_name: 'Jennifer', last_name: 'Williams', email: 'jw@example.com', account_id: account.id, location_id: aurora.id) }
  let!(:deal) { company.deals.create!(name: 'Williams home', account_id: account.id, contact_id: contact.id, location_id: aurora.id) }
  let!(:elsewhere) { company.deals.create!(name: 'Other buyer', contact_id: contact.id, location_id: aurora.id) }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'X-Location-ID' => denver.id.to_s }
  end

  def ids(json) = Array(json.is_a?(Hash) ? (json['deals'] || json['contacts'] || json['data'] || json['items']) : json).map { |r| r['id'].to_i }

  it "lists the account's deals and contacts while the selector is on another location" do
    get '/api/crm/deals', params: { account_id: account.id }, headers: headers
    expect(ids(JSON.parse(response.body))).to eq([deal.id])

    get '/api/v1/contacts', params: { account_id: account.id }, headers: headers
    expect(ids(JSON.parse(response.body))).to include(contact.id)
  end

  it 'still narrows the full lists to the selected location' do
    get '/api/crm/deals', headers: headers
    expect(ids(JSON.parse(response.body))).not_to include(deal.id)
  end
end
