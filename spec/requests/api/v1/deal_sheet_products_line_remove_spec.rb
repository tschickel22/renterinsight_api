# frozen_string_literal: true

require 'rails_helper'

# Tom, 2026-11-05 (Factory Direct, deal 449): Package C and Summit Kitchen were
# added in Products before the deal sheet existed, then picked again on the
# sheet, so the deal charged them twice. The sheet showed the Products copies
# with no way to remove them. The sheet now removes them through the deal line,
# and the delete reprices the sheet and the deal.
RSpec.describe 'Removing a Products line from the deal sheet', type: :request do
  let(:company) do
    Company.create!(name: "Factory Direct #{SecureRandom.hex(3)}").tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true)
      c.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
      c.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
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

  before do
    factory.update!(truebuild_released_at: Time.current)
    company.dealer_factories.create!(factory: factory)
  end

  def body = JSON.parse(response.body)

  it 'takes the line off the deal and out of the sheet total' do
    contact = company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "pat-#{SecureRandom.hex(3)}@example.com")
    deal = company.deals.create!(name: 'Smith Apex', contact_id: contact.id)
    post "/api/v1/deals/#{deal.id}/home_build", headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)
    without = body.dig('build', 'totals', 'retail')

    # Written straight to the deal, as an older Products save left it: not yet taken into the sheet.
    extra = deal.deal_products.create!(product_name: 'AP Package C', quantity: 1, unit_price: 23_243, cost: 14_995,
                                       total: 23_243, tax: 0, notes: 'category:product, source:template', source_type: 'template')
    Truebuild::DealBuild.new(deal.reload.home_build).reprice!
    get "/api/v1/deals/#{deal.id}/home_build", headers: headers
    expect(body.dig('build', 'other_deal_lines').map { |l| l['name'] }).to eq(['AP Package C'])
    expect(body.dig('build', 'totals', 'retail')).to eq(without + 23_243)

    delete "/api/crm/deals/#{deal.id}/products/#{extra.id}", headers: headers
    expect(response).to have_http_status(:no_content)

    get "/api/v1/deals/#{deal.id}/home_build", headers: headers
    expect(body.dig('build', 'other_deal_lines')).to eq([])
    expect(body.dig('build', 'totals', 'retail')).to eq(without)
    expect(DealProduct.exists?(extra.id)).to be(false)
  end
end
