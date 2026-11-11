# frozen_string_literal: true

require 'rails_helper'

# Tom, 2026-11-04: surcharges change most, often as dollars per square foot by
# section count, so one rule covers a plant. Homes no price book has start from
# All other homes figures and what inventory says, and a catalog home that
# inventory lists at another price warns the rep.
RSpec.describe 'Stand-alone home pricing and surcharge rules', type: :request do
  let(:company) do
    Company.create!(name: "Dealer #{SecureRandom.hex(3)}").tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true)
      c.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
      c.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 2)
    end
  end
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:double) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: 'D2856', width_ft: 28, length_ft: 56, building_code: 'HUD') }
  let(:single) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: 'S1670', width_ft: 16, length_ft: 70, square_feet: 1000, building_code: 'HUD') }
  let(:no_size) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: 'NOSIZE', building_code: 'HUD') }
  let!(:double_price) { CatalogVariantPrice.create!(price_book: book, variant: double, net_base_price: 50_000, total_base_price: 51_000) }
  let!(:single_price) { CatalogVariantPrice.create!(price_book: book, variant: single, net_base_price: 30_000, total_base_price: 30_500) }
  let!(:no_size_price) { CatalogVariantPrice.create!(price_book: book, variant: no_size, net_base_price: 20_000, total_base_price: 20_100) }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:body) { JSON.parse(response.body) }
  let(:rules_path) { '/api/v1/truebuild_pricing/surcharge_rules' }
  before do
    factory.update!(truebuild_released_at: Time.current)
    company.dealer_factories.create!(factory: factory)
  end

  def new_deal(**attrs)
    contact = company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "pat-#{SecureRandom.hex(3)}@example.com")
    company.deals.create!({ name: 'Sale', contact: contact }.merge(attrs))
  end

  def sheet_path(deal) = "/api/v1/deals/#{deal.id}/home_build"

  def surcharge_on(variant) = Truebuild::DealerPrices.new(company).surcharge_for(CatalogVariantPrice.find_by!(catalog_plan_variant_id: variant.id))

  describe 'surcharge rules' do
    let(:rules) do
      [{ factory_id: factory.id, section: 'double', basis: 'per_sq_ft', amount: 5 },
       { factory_id: factory.id, section: 'single', basis: 'flat', amount: 2_000 },
       { section: 'any', basis: 'per_sq_ft', amount: 1 }]
    end

    it 'previews without saving, then one save prices every home by size and section' do
      put rules_path, headers: headers, params: { manufacturer_id: mfr.id, rules: rules, preview: true }.to_json
      expect(response).to have_http_status(:ok)
      effect = body['effect'].first
      expect(effect).to include('homes' => 3, 'changed' => 2, 'no_size' => 1, 'keep_own' => 0)
      expect(effect['samples'].map { |s| [s['model_number'], s['now'], s['new']] }).to contain_exactly(['D2856', 1000.0, 7840.0], ['S1670', 500.0, 2000.0])
      expect(company.dealer_surcharge_rules.count).to eq(0)

      put rules_path, headers: headers, params: { manufacturer_id: mfr.id, rules: rules }.to_json
      expect(response).to have_http_status(:ok)
      expect(surcharge_on(double)).to eq(7840) # 28 x 56 x $5
      expect(surcharge_on(single)).to eq(2000)
      expect(surcharge_on(no_size)).to be_nil # no size: stays on the book's figure
    end

    it 'prices the home with it, marked up, and a figure set on one home still wins' do
      company.dealer_surcharge_rules.create!(manufacturer: mfr, section: 'double', amount: 5)
      get "/api/v1/truebuild_pricing/price_list", headers: headers, params: { book_id: book.id }
      expect(body['rows'].find { |r| r['model_number'] == 'D2856' }['rule_surcharge']).to eq(7840.0)

      result = Truebuild::PricingEngine.new(company: company, variant: double).call
      expect(result.lines.first[:cost]).to eq(57_840.0)
      expect(result.lines.first[:retail]).to eq(115_680.0)

      Truebuild::DealerPrices.set_surcharge!(company: company, row: double_price, value: '100', label: 'one home')
      expect(surcharge_on(double)).to eq(100)
    end

    it 'keeps its price on an open sheet up to date when a rule is removed' do
      rule = company.dealer_surcharge_rules.create!(manufacturer: mfr, section: 'double', amount: 5)
      post sheet_path(new_deal), headers: headers, params: { variant_id: double.id }.to_json
      build = DealHomeBuild.last
      expect(build.lines.find_by(kind: 'base').cost).to eq(57_840)
      expect(Truebuild::DealBuild.stale?(build)).to be(false)

      travel 2.seconds do
        put rules_path, headers: headers, params: { manufacturer_id: mfr.id, rules: [] }.to_json
        expect(rule.reload.active).to be(false)
        expect(Truebuild::DealBuild.stale?(build.reload)).to be(true)
      end
    end

    it 'keeps a HUD rule off modular homes at the same plant, the way the books really are' do
      modular = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: 'M2856', width_ft: 28, length_ft: 56, building_code: 'MOD')
      CatalogVariantPrice.create!(price_book: book, variant: modular, net_base_price: 60_000, total_base_price: 69_000)
      company.dealer_surcharge_rules.create!(manufacturer: mfr, building_code: 'HUD', section: 'double', amount: 2.65)
      expect(surcharge_on(double)).to eq(4155.2)
      expect(surcharge_on(modular)).to be_nil
      company.dealer_surcharge_rules.create!(manufacturer: mfr, building_code: 'MOD', section: 'double', basis: 'flat', amount: 8_000)
      expect(Truebuild::DealerPrices.new(company).surcharge_for(CatalogVariantPrice.find_by!(catalog_plan_variant_id: modular.id))).to eq(8000)
      expect(surcharge_on(double)).to eq(4155.2)
    end

    it 'refuses two rows for the same plant and section' do
      put rules_path, headers: headers, params: { manufacturer_id: mfr.id, rules: [{ section: 'double', amount: 1 }, { section: 'double', amount: 2 }] }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'the price list grid' do
    let(:grid_path) { '/api/v1/truebuild_pricing/price_list/grid' }
    let(:admin_headers) do
      user = User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A', password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
      { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
    end

    it 'gives a dealer their own three columns in one save, and keeps the shared book from them' do
      post grid_path, headers: headers, params: { book_id: book.id, kind: 'base', rows: [
        { price_id: double_price.id, cost: 49_000, surcharge: 3_500, price: 99_000 }, { price_id: single_price.id, surcharge: 700 }
      ] }.to_json
      expect(response).to have_http_status(:ok)
      row = body['rows'].first
      expect(row).to include('your_cost' => 49_000.0, 'your_surcharge' => 3500.0, 'your_price' => 99_000.0)
      expect(surcharge_on(single)).to eq(700)

      post grid_path, headers: headers, params: { book_id: book.id, kind: 'base', rows: [{ price_id: double_price.id, factory_surcharge: 1 }] }.to_json
      expect(response).to have_http_status(:forbidden)
      expect(double_price.reload.total_base_price).to eq(51_000)
    end

    it 'lets a platform admin correct the factory base and surcharge, keeping the surcharge when only the base moves' do
      get '/api/v1/truebuild_pricing/price_list', headers: admin_headers, params: { book_id: book.id }
      expect(body['can_edit_factory']).to be(true)
      post grid_path, headers: admin_headers, params: { book_id: book.id, kind: 'base', rows: [
        { price_id: double_price.id, factory_cost: 52_000 }, { price_id: single_price.id, factory_surcharge: 2_500 }
      ] }.to_json
      expect(response).to have_http_status(:ok)
      expect(double_price.reload).to have_attributes(net_base_price: 52_000, total_base_price: 53_000)
      expect(single_price.reload).to have_attributes(net_base_price: 30_000, total_base_price: 32_500)
      expect(CatalogPriceCorrection.where(price_book: book).count).to eq(3)
    end

    it 'saves nothing when one row is bad' do
      post grid_path, headers: headers, params: { book_id: book.id, kind: 'base', rows: [{ price_id: double_price.id, price: 99_000 }, { price_id: single_price.id, surcharge: -5 }] }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(company.dealer_markup_rules.where(markup_type: 'manual').count).to eq(0)
    end
  end

  describe 'All other homes' do
    before { company.dealer_catalog_terms.find_by(manufacturer_id: nil).update!(dealer_pack: 2_000, sale_discount_pct: 10) }

    it 'reaches a builder with no figure of its own; $0 on a builder keeps it out' do
      expect(DealerCatalogTerm.effective(company, mfr.id).dealer_pack).to eq(2000)
      expect(DealerCatalogTerm.effective(company, mfr.id).sale_discount_pct).to eq(10)
      company.dealer_catalog_terms.create!(manufacturer: mfr, dealer_pack: 0)
      expect(DealerCatalogTerm.effective(company, mfr.id).dealer_pack).to eq(0)
    end

    it 'is what a typed home starts from, with the All homes markup' do
      get sheet_path(new_deal), headers: headers
      expect(body.dig('start_from', 'typed_defaults')).to include('pack' => 2000.0, 'discount_pct' => 10.0)
      expect(body.dig('start_from', 'typed_defaults', 'markup')).to include('times' => 2.0)
    end
  end

  describe 'a typed home' do
    it 'takes retail and discount as typed, shows the savings, and counts the pack in cost' do
      deal = new_deal
      post sheet_path(deal), headers: headers,
                             params: { manual_home: { description: '2018 Clayton', cost: 50_000, pack: 3_000, price: 106_000, discount_pct: 25 } }.to_json
      expect(response).to have_http_status(:created)
      totals = body.dig('build', 'totals')
      expect(totals['gross']).to eq(106_000.0)
      expect(totals.dig('discounts', 'sale')).to eq(26_500.0)
      expect(totals['pack']).to eq(3000.0)
      expect(deal.reload.pack_amount).to eq(3000)
    end

    it 'takes back a pack it filled when the sheet is cleared, and leaves one someone set' do
      deal = new_deal
      post sheet_path(deal), headers: headers, params: { manual_home: { description: '2018 Clayton', cost: 50_000, pack: 3_000, price: 100_000 } }.to_json
      expect(deal.reload.pack_amount).to eq(3000)
      delete sheet_path(deal), headers: headers
      expect(response).to have_http_status(:no_content)
      expect(deal.reload.pack_amount).to be_nil

      set = new_deal(pack_amount: 2_500)
      post sheet_path(set), headers: headers, params: { manual_home: { description: '2019 Clayton', cost: 50_000, price: 100_000 } }.to_json
      expect(set.reload.pack_amount).to eq(2500)
      delete sheet_path(set), headers: headers
      expect(set.reload.pack_amount).to eq(2500)
    end

    it 'shows what inventory says about a home with no catalog model' do
      vehicle = company.vehicles.create!(vin: SecureRandom.hex(8), make: 'Clayton', model: 'Ultra', year: 2018, dealer_cost: 40_000, msrp: 80_000, pack_amount: 1_500,
                                         special_discount_enabled: true, discount_type: '$ Flat Amount', discount_value: 5_000)
      get sheet_path(new_deal(vehicle: vehicle)), headers: headers
      expect(body.dig('start_from', 'home', 'inventory')).to include('cost' => 40_000.0, 'price' => 80_000.0, 'pack' => 1500.0, 'discount_amount' => 5000.0)
    end
  end

  describe 'a catalog home with an asking price in inventory (Tom 2026-11-11)' do
    let(:vehicle) { company.vehicles.create!(vin: SecureRandom.hex(8), make: 'Champion', model: 'Apex', year: 2026, catalog_plan_variant_id: double.id, msrp: 90_000) }

    it 'starts the sheet at the asking price, with nothing to warn about' do
      post sheet_path(new_deal(vehicle: vehicle)), headers: headers, params: { variant_id: double.id, vehicle_id: vehicle.id }.to_json
      expect(response).to have_http_status(:created)
      base = body.dig('build', 'lines').find { |l| l['kind'] == 'base' }
      expect(base['unit_retail'].to_f).to eq(90_000.0)
      expect(body.dig('build', 'totals', 'warnings').join).not_to include('Inventory lists')
    end

    it 'uses the price list and markup when no asking price is typed' do
      vehicle.update!(msrp: nil)
      post sheet_path(new_deal(vehicle: vehicle)), headers: headers, params: { variant_id: double.id, vehicle_id: vehicle.id }.to_json
      base = body.dig('build', 'lines').find { |l| l['kind'] == 'base' }
      expect(base['unit_retail'].to_f).not_to eq(90_000.0)
      expect(base['unit_retail'].to_f).to be_positive
    end
  end

  it 'lets inventory readers fetch the defaults a home starts from' do
    get '/api/v1/truebuild_pricing/home_defaults', headers: headers
    expect(response).to have_http_status(:ok)
    expect(body['markup']).to include('times' => 2.0)
  end
end
