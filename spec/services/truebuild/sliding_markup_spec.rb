# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Sliding scale markup' do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let(:settings) { { sliding_multiplier: 85, sliding_curve: 0.454, minimum_markup: 27_368 } }
  let(:rule) { company.dealer_markup_rules.create!(scope_type: 'all', applies_to: 'base_and_options', markup_type: 'sliding', **settings) }

  # Figures from the dealer's own sheet (Markup Formula tab and Base Price List).
  {
    30_000 => 57_368.00,
    40_000 => 67_678.57,
    50_000 => 81_264.86,
    60_000 => 94_537.39,
    108_565 => 156_307.55,
    111_000 => 159_324.27
  }.each do |cost, retail|
    it "prices #{cost} at #{retail}" do
      expect(rule.apply(cost).to_f).to be_within(0.01).of(retail)
    end
  end

  it 'needs its settings, and only fits a whole-home rule' do
    bad = company.dealer_markup_rules.build(scope_type: 'all', applies_to: 'base', markup_type: 'sliding')
    expect(bad).not_to be_valid
    expect(bad.errors.attribute_names).to include(:sliding_multiplier, :sliding_curve)

    expect(company.dealer_markup_rules.build(scope_type: 'option', scope_id: 1, applies_to: 'base', markup_type: 'sliding', **settings)).not_to be_valid
    expect(company.dealer_markup_rules.build(scope_type: 'all', applies_to: 'options', markup_type: 'sliding', **settings)).not_to be_valid
  end

  describe 'on a home with options' do
    let(:mfr) { Manufacturer.create!(name: "Mfr #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
    let(:factory) { mfr.factories.create!(name: 'Plant', code: "P#{SecureRandom.hex(2)}") }
    let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Elite', name: 'Home') }
    let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856A', width_ft: 28, length_ft: 56, building_code: 'HUD') }
    let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Book', status: 'published') }
    let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'c', name: 'Construction') }

    def option(name, cost)
      opt = CatalogOption.create!(group: group, manufacturer: mfr, key: "c--#{name}", name: name)
      CatalogOptionPrice.create!(price_book: book, option: opt, dealer_cost: cost)
      opt
    end

    def priced(cost, option_ids)
      CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: cost)
      rule
      Truebuild::PricingEngine.new(company: company, variant: variant, book: book, option_ids: option_ids).call
    end

    it 'comes to what the scale says for the whole invoice, base and options together' do
      a = option('a', 7_000)
      b = option('b', 3_000)
      result = priced(100_000, [a.id, b.id])
      base, *options = result.lines

      expect(base[:retail]).to eq(rule.apply(100_000).to_f.round(2))
      expect(result.totals[:retail]).to be_within(0.01).of(rule.apply(110_000).to_f)
      expect(options.first[:retail] / options.last[:retail]).to be_within(0.01).of(7.0 / 3.0)
      expect(base[:detail][:rule]).to eq('Every home rule: sliding scale, at least $27,368 over cost')
    end

    it 'prices one option as what it adds to the home' do
      a = option('a', 10_000)
      CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 100_000)
      rule
      engine = Truebuild::PricingEngine.new(company: company, variant: variant, book: book)
      row = CatalogOptionPrice.find_by(catalog_option_id: a.id)
      expect(engine.retail_for(row)).to be_within(0.01).of((rule.apply(110_000) - rule.apply(100_000)).to_f)
    end

    it 'adds only cost while the home sits on the minimum' do
      a = option('a', 2_000)
      result = priced(30_000, [a.id])
      expect(result.lines.last[:retail]).to eq(2_000)
    end

    it 'leaves a rule written for one option alone' do
      a = option('a', 7_000)
      company.dealer_markup_rules.create!(scope_type: 'option', scope_id: a.id, applies_to: 'options', markup_type: 'percent', value: 10)
      result = priced(100_000, [a.id])
      expect(result.lines.last[:retail]).to eq(7_700)
    end
  end

  it 'hands its settings to typed-in and inventory homes, which have no book to price them' do
    rule
    markup = Truebuild::StandAlonePricing.new(company).defaults[:markup]
    expect(markup).to include(type: 'sliding', times: nil, sliding_multiplier: 85.0, sliding_curve: 0.454, minimum_markup: 27_368.0)
  end
end
