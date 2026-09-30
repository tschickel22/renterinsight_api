# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::PricingEngine do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856M32392', width_ft: 28, length_ft: 56) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'construction', name: 'Construction') }

  def option(name, **price)
    opt = CatalogOption.create!(group: group, manufacturer: mfr, key: "construction--#{name.parameterize}", name: name)
    Array.wrap(price[:rows] || [price]).each { |row| CatalogOptionPrice.create!(price_book: book, option: opt, **row) }
    opt
  end

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 57_995,
                                required_adders: [{ name: 'MOD conversion', amount: 3150 }, { name: 'Drywall', amount: 4770 }])
  end

  def price(**kw) = described_class.new(company: company, variant: variant, **kw).call

  it 'prices the base from net plus required adders, less the program discount, through the markup rule' do
    company.dealer_catalog_terms.create!(manufacturer: mfr, program_discount_pct: 2)
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.3)

    base = price.lines.first
    expect(base[:detail][:program_discount]).to eq(1318.3) # 2% of 65,915
    expect(base[:cost]).to eq(64_596.7)
    expect(base[:retail]).to eq(83_975.71)
    expect(base[:detail][:rule]).to eq('all rule: 1.3 x cost')
  end

  it 'uses the most specific rule, and a location rule over the company one' do
    loc = company.locations.create!(name: 'Denver', timezone: 'UTC')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.3)
    company.dealer_markup_rules.create!(scope_type: 'series', manufacturer: mfr, scope_value: 'aspire', markup_type: 'percent', value: 25)
    company.dealer_markup_rules.create!(scope_type: 'series', manufacturer: mfr, scope_value: 'Aspire', location: loc,
                                        markup_type: 'percent', value: 20)

    expect(price.lines.first[:detail][:rule]).to eq('series rule: 25.0% over cost')
    expect(price(location: loc).lines.first[:retail]).to eq(79_098.0)

    company.dealer_markup_rules.create!(scope_type: 'plan', scope_id: plan.id, markup_type: 'manual', value: 89_900)
    expect(price(location: loc).lines.first[:retail]).to eq(89_900.0)
  end

  it 'prices options by the row for this model, with factory suggested retail when the dealer has no option rule' do
    company.dealer_markup_rules.create!(scope_type: 'all', applies_to: 'base', markup_type: 'multiplier', value: 1.3)
    drywall = option('Drywall T/O', rows: [
      { dealer_cost: 4815, suggested_retail: 7463.25, max_length_ft: 47, section_type: 'multi' },
      { dealer_cost: 5065, suggested_retail: 7850.75, min_length_ft: 48, max_length_ft: 56, section_type: 'multi' }
    ])
    knobs = option('Cabinet Knobs', dealer_cost: 65, suggested_retail: 100.75)
    std = option('Wrapped Shaker Cabinets', is_standard: true)
    other = option('Model-only porch', dealer_cost: 900, variant: CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2876H42180'))

    r = price(option_ids: [drywall.id, knobs.id, std.id, other.id])
    opts = r.lines.select { |l| l[:kind] == 'option' }.index_by { |l| l[:label] }
    expect(opts['Drywall T/O']).to include(cost: 5065.0, retail: 7850.75)
    expect(opts['Drywall T/O'][:detail][:rule]).to eq('factory suggested retail')
    expect(opts['Wrapped Shaker Cabinets']).to include(cost: 0.0, retail: 0.0)
    expect(opts).not_to have_key('Model-only porch')
    expect(r.warnings).to include('Model-only porch is not offered on 2856M32392.')

    company.dealer_markup_rules.create!(scope_type: 'option_group', scope_id: group.id, applies_to: 'options',
                                        markup_type: 'multiplier', value: 1.4)
    expect(price(option_ids: [knobs.id]).lines.last).to include(retail: 91.0)
  end

  it 'adds freight, rounds the retail up, and warns under the margin floor' do
    company.dealer_catalog_terms.create!(manufacturer: mfr, freight_flat: 500, freight_per_mile: 4.5, freight_miles: 200,
                                         round_retail_to: 5, margin_floor_pct: 90) # ignored: company-wide settings
    company.dealer_catalog_terms.create!(round_retail_to: 100, margin_floor_pct: 25)
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.2)

    r = price
    expect(r.lines.last).to include(kind: 'freight', cost: 1400.0, retail: 1400.0)
    expect(r.totals[:cost]).to eq(67_315.0)
    expect(r.totals[:retail]).to eq(80_500.0) # 79,098 + 1,400 = 80,498, rounded up to the next 100
    expect(r.warnings.join).to include('under your 25.0% floor')
  end

  it 'has no retail and says so when no rule covers the home' do
    r = price
    expect(r.totals[:retail]).to be_nil
    expect(r.warnings.first).to include('Add a markup rule')
  end

  it 'keeps a reviewing dealer on the book they adopted until they accept the new one' do
    company.dealer_catalog_terms.create!(price_update_policy: 'review')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.0)
    newer = CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2027')
    CatalogVariantPrice.create!(price_book: newer, variant: variant, net_base_price: 60_000)
    book.update!(status: 'superseded')
    newer.update!(status: 'published', supersedes: book)

    company.dealer_price_book_adoptions.create!(price_book: newer, status: 'pending')
    expect(price.book).to eq(book)

    company.dealer_price_book_adoptions.find_by(price_book: newer).update!(status: 'adopted')
    expect(price.book).to eq(newer)
    expect(price.lines.first[:cost]).to eq(60_000.0)
  end

  it 'gives a buyer retail only' do
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.3)
    shown = price.retail_only
    expect(shown.to_s).not_to include('cost')
    expect(shown[:total]).to eq(85_689.5)
  end
end
