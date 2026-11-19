# frozen_string_literal: true

require 'rails_helper'

# The dealer address read `street` and `zip`, which are not columns, so the
# street and ZIP never printed. It now reads the agreement's location first,
# then the company, like the Dealer Logo.
RSpec.describe 'Agreement merge fields: dealer address and phone', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  def dealer_fields(params = {})
    get '/api/v1/agreement_merge_fields', params: params, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body['merge_fields'].values.flat_map { |g| g['fields'] }
            .to_h { |f| [f['key'], f['value']] }.slice('company.address', 'company.phone')
  end

  it "prints the company's street, city, state and ZIP" do
    company.update_columns(address_line1: '3710 Highway 45 North', city: 'Columbus', state: 'MS', zip_code: '39705', phone: '662-555-0100')

    expect(dealer_fields).to eq('company.address' => '3710 Highway 45 North, Columbus, MS 39705', 'company.phone' => '662-555-0100')
  end

  it "prefers the agreement's location when it has an address and phone" do
    company.update_columns(address_line1: '1 Main St', city: 'Jackson', state: 'MS', zip_code: '39201', phone: '601-555-0100')
    location = company.locations.create!(name: 'Gulf Lot')
    location.update_columns(address_line1: '200 Beach Blvd', city: 'Biloxi', state: 'MS', zip_code: '39530', phone: '228-555-0100')

    expect(dealer_fields(location_id: location.id)).to eq('company.address' => '200 Beach Blvd, Biloxi, MS 39530', 'company.phone' => '228-555-0100')
  end

  it 'falls back to the company when the location has none' do
    company.update_columns(address_line1: '1 Main St', city: 'Jackson', state: 'MS', zip_code: '39201', phone: '601-555-0100')
    location = company.locations.create!(name: 'Office')

    expect(dealer_fields(location_id: location.id)).to eq('company.address' => '1 Main St, Jackson, MS 39201', 'company.phone' => '601-555-0100')
  end
end
