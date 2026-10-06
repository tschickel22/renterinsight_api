# frozen_string_literal: true

require 'rails_helper'

# B28: a manufactured home was taxed on its full price by the delivery state.
# The states Factory Direct sells into each tax it differently.
RSpec.describe Tax::DealTax do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let(:lot) { company.locations.create!(name: 'Auburn', state: 'IN', timezone: 'UTC') }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "p#{SecureRandom.hex(2)}@example.com") }

  def deal(**attrs)
    company.deals.create!({ name: 'Sale', contact_id: buyer.id, location_id: lot.id }.merge(attrs))
  end

  def tax(d, price: 83_688.70, **kw) = described_class.new(deal: d, selling_price: price, **kw).call

  it 'taxes Indiana on 65% of the price after trade, at the 7% state rate until the dealer sets one' do
    r = tax(deal(delivery_state: 'Indiana'), trade: 0)
    # Factory Direct's sheet: 83,688.70 x 65% = 54,397.66; 7% = 3,807.84.
    expect(r).to include(state: 'IN', payer: 'dealer_collects', base: 54_397.66, collected: 3807.84, rate: 7.0)
    expect(r[:note]).to include("IN's 7% state rate")
    expect(r[:disclosure]).to include('IC 6-2.5-5-29')

    expect(tax(deal(delivery_state: 'IN'), trade: 10_000)[:base]).to eq(((83_688.70 - 10_000) * 0.65).round(2))
  end

  it "taxes a buyer who picks up at the dealer's Indiana lot as Indiana, wherever the home goes" do
    r = tax(deal(delivery_state: 'MI', delivery_point: 'lot'))
    expect(r).to include(state: 'IN', collected: 3807.84)
  end

  it 'collects nothing in Michigan (paid at titling) and has the dealer owe Ohio use tax on cost' do
    mi = tax(deal(delivery_state: 'MI'))
    expect(mi).to include(state: 'MI', payer: 'buyer_at_titling', collected: 0.0)
    expect(mi[:at_titling]).to eq((83_688.70 * 0.06).round(2))

    oh = tax(deal(delivery_state: 'OH'), cost_basis: 60_256, freight_cost: 7065)
    # (60,256 + 7,065 freight) x 7.25% = 4,880.77, owed by the dealer, not charged to the buyer.
    expect(oh).to include(state: 'OH', payer: 'dealer_use_tax', collected: 0.0, use_tax: 4880.77)
  end

  it 'exempts a pre-owned home in Indiana, and taxes other states on the whole price as before' do
    expect(tax(deal(delivery_state: 'IN'), used: true)).to include(exempt: true, collected: 0.0)

    AccountingSettings.for_company(company).update!(tax_rates_by_state: { 'CO' => { 'state' => '2.9', 'county' => '1.0' } })
    co = tax(deal(delivery_state: 'CO'), price: 100_000, trade: 20_000)
    expect(co).to include(state: 'CO', base: 100_000.0, collected: 3900.0)
    expect(co[:slots]).to eq(state: 2900.0, county: 1000.0, city: 0.0)
  end

  it "uses the dealer's own rules for a state over the defaults" do
    AccountingSettings.for_company(company)
                      .update!(tax_rates_by_state: { 'IN' => { 'state' => '7', 'rules' => { 'taxable_pct' => 100 } } })
    r = tax(deal(delivery_state: 'IN'), price: 50_000)
    expect(r).to include(base: 50_000.0, collected: 3500.0, note: nil)
  end
end
