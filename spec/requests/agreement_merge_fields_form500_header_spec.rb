# frozen_string_literal: true

require 'rails_helper'

# Coastal Breeze agreement 90 (deal 659): the Form 500's optional equipment rows
# stayed empty because deal_products keep their category in notes and agreements
# read it as blank; the serial printed the catalog placeholder CAT-20-tremor-L83;
# and single/double wide never ticked because catalog homes have no sections.
RSpec.describe 'Agreement merge fields: Form 500 options and home header', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:buyer) { company.contacts.create!(first_name: 'Keia', last_name: 'Walker', email: 'k@example.com') }
  let(:home) do
    company.vehicles.create!(year: 2026, make: 'Live Oak', model: 'Tremor', condition: 'new', status: 'available_to_order',
                             listing_type: 'manufactured_home', inventory_id: 'MH-20261113-1BFEF8',
                             serial_number: 'CAT-20-tremor-L83', length: 80, width: 28, bedrooms: 4, bathrooms: 3)
  end
  let(:deal) { company.deals.create!(name: 'Walker home', contact_id: buyer.id, vehicle_id: home.id) }

  def fetch
    get '/api/v1/agreement_merge_fields', params: { deal_id: deal.id }, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def field(body, key)
    body['merge_fields'].values.flat_map { |g| g['fields'] }.find { |f| f['key'] == key }&.dig('value')
  end

  before do
    deal.deal_products.create!(product_name: '2026 Live Oak Tremor', quantity: 1, unit_price: 161_000, source_type: 'home',
                               notes: 'category:home, source:home')
    deal.deal_products.create!(product_name: 'Skirting (Metal)', quantity: 1, unit_price: 2400,
                               notes: 'category:service, source:standard_item')
    deal.deal_products.create!(product_name: 'Porch', quantity: 1, unit_price: 1500, notes: 'category:accessory')
    deal.deal_products.create!(product_name: 'Doc fee', quantity: 1, unit_price: 499, notes: 'category:fee')
  end

  it 'lists every line but the home and fees as options, and totals them' do
    body = fetch
    expect(body.dig('line_item_values', 'deal.line_items_options[0].description')).to eq('Skirting (Metal)')
    expect(body.dig('line_item_values', 'deal.line_items_options[1].description')).to eq('Porch')
    expect(body['line_item_values'].keys.grep(/line_items_options\[2\]/)).to be_empty
    expect(field(body, 'deal.options_total_from_lines').to_f).to eq(3900.0)
    expect(body.dig('line_item_counts', 'line_items_options')).to eq(2)
  end

  it 'gives the key that explains the * on non-taxable lines' do
    expect(field(fetch, 'deal.tax_mark_key')).to eq('* Not taxable')
  end

  it 'reads the category tag, so the fee and accessory subtotals fill' do
    body = fetch
    expect(field(body, 'deal.fee_total').to_f).to eq(499.0)
    expect(field(body, 'deal.accessory_total_from_lines').to_f).to eq(1500.0)
  end

  it 'never prints a catalog placeholder serial' do
    body = fetch
    expect(field(body, 'vehicle.serial_number')).to be_nil
    expect(field(body, 'vehicle.home_description')).not_to include('CAT-')
  end

  it 'keeps a real serial' do
    home.update!(serial_number: 'LOH123456AB')
    expect(field(fetch, 'vehicle.serial_number')).to eq('LOH123456AB')
  end

  it 'falls back to the inventory id for stock number and reads sections from width' do
    body = fetch
    expect(field(body, 'vehicle.stock_number')).to eq('MH-20261113-1BFEF8')
    expect(field(body, 'vehicle.is_multi_section')).to eq('true')
    expect(field(body, 'vehicle.is_single_section')).to be_nil
  end
end
