# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Leads::Converter, 'home chosen on the lead' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:home) do
    company.vehicles.create!(listing_type: 'manufactured_home', year: 2026, make: 'Live Oak', model: 'Tremor',
                             serial_number: "SN#{SecureRandom.hex(4)}", bedrooms: 4, bathrooms: 2,
                             msrp: 161_000, dealer_cost: 119_659)
  end

  def convert(lead) = described_class.new(lead, company: company, user: user).call(deal_params: { name: 'Walker' }).deal

  def lead_with(vehicle_id)
    company.leads.create!(first_name: 'Keianna', last_name: 'Walker', email: 'k@example.com', vehicle_id: vehicle_id)
  end

  it 'puts the home on the deal as its home line' do
    deal = convert(lead_with(home.id))
    line = deal.deal_products.reload.sole

    expect(deal.vehicle_id).to eq(home.id)
    expect(line).to be_home_line_item
    expect(line.product_name).to eq('2026 Live Oak Tremor')
    expect(line.unit_price).to eq(161_000)
    expect(line.cost).to eq(119_659)
    expect(deal.reload.value).to eq(161_000)
  end

  it "taxes the home at the dealer's rate for the buyer's state, like a home added from inventory" do
    AccountingSettings.for_company(company).update!(default_state_tax_rate: 3, default_county_tax_rate: 1, default_city_tax_rate: 1,
                                                    tax_rates_by_state: { 'MS' => { 'state' => 7, 'county' => 0, 'city' => 0 } })
    lead = lead_with(home.id)
    lead.update!(state: 'MS') if lead.respond_to?(:state)
    line = convert(lead).deal_products.reload.sole

    expect(line.tax).to eq(11_270)
    expect(line.total).to eq(172_270)
    expect(line.notes).not_to include('taxable:no')
  end

  it 'marks the home untaxed when the dealer charges no tax' do
    AccountingSettings.for_company(company).update!(default_state_tax_rate: 0, default_county_tax_rate: 0, default_city_tax_rate: 0)
    line = convert(lead_with(home.id)).deal_products.reload.sole

    expect(line.tax).to eq(0)
    expect(line.notes).to include('taxable:no')
  end

  it 'adds no line when the lead has no home' do
    expect(convert(lead_with(nil)).deal_products.reload).to be_empty
  end
end
