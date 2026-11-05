# frozen_string_literal: true

require 'rails_helper'

# Tom, 2026-11-04: the pack is overhead in every home's cost, so the Deal Sheet's
# margin is after it, for the builders the dealer sets it on. The deal's own pack
# is the one figure: commissions take it off. The home's cost, the factory PO and
# accounting front gross stay at what the factory bills.
RSpec.describe 'Deal Sheet dealer pack', type: :request do
  let(:company) do
    Company.create!(name: "Factory Direct #{SecureRandom.hex(3)}").tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true)
      c.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
      c.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 2)
    end
  end
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let!(:base_price) { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 50_000) }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def deal_with_sheet(**deal_attrs)
    contact = company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "pat-#{SecureRandom.hex(3)}@example.com")
    deal = company.deals.create!(name: 'Smith Apex', contact_id: contact.id, **deal_attrs)
    post "/api/v1/deals/#{deal.id}/home_build", headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)
    deal
  end

  def totals = JSON.parse(response.body).dig('build', 'totals')
  def base_line = JSON.parse(response.body).dig('build', 'lines').find { |l| l['kind'] == 'base' }

  it 'counts the builder pack in sheet cost and retail, writes it to the deal, and leaves the home line at factory cost' do
    company.dealer_catalog_terms.create!(manufacturer_id: mfr.id, dealer_pack: 3000)
    deal = deal_with_sheet

    expect(totals).to include('pack' => 3000.0, 'gross' => 107_980.0, 'cost' => 54_650.0)
    expect(base_line['unit_cost'].to_f).to eq(50_000.0)
    expect(totals['margin']).to eq(totals['retail'] - totals['cost'])

    deal.reload
    expect(deal.pack_amount).to eq(3000)
    expect(deal.home_line_item.cost).to eq(51_650) # base plus freight, no pack
    expect(deal.commissionable_front_gross).to eq(deal.front_gross - 3000)
  end

  it 'charges no pack for a builder without one until All other homes is set, and $0 keeps a builder out' do
    deal = deal_with_sheet
    expect(totals).to include('pack' => 0.0, 'gross' => 101_980.0, 'cost' => 51_650.0)
    expect(deal.reload.pack_amount).to be_nil

    company.dealer_catalog_terms.find_by(manufacturer_id: nil).update!(dealer_pack: 3000)
    deal_with_sheet
    expect(totals).to include('pack' => 3000.0)

    company.dealer_catalog_terms.create!(manufacturer_id: mfr.id, dealer_pack: 0)
    deal_with_sheet
    expect(totals).to include('pack' => 0.0)
  end

  it 'keeps a pack already set on the deal' do
    company.dealer_catalog_terms.create!(manufacturer_id: mfr.id, dealer_pack: 3000)
    deal = deal_with_sheet(pack_amount: 1500)

    expect(totals['pack']).to eq(1500.0)
    expect(deal.reload.pack_amount).to eq(1500)
  end
end
