# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::BookTransfer do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka, Dutch Housing', code: "TOP#{SecureRandom.hex(2)}", state: 'KS') }
  let(:decatur) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:photo) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-kitchen-1' }
  let!(:book) do
    CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: 'Topeka 2026', status: 'published',
                             published_at: Time.zone.parse('2026-09-01'), effective_on: Date.new(2026, 9, 1))
  end

  before do
    # One model built at Decatur but priced in Topeka's package.
    plan = CatalogPlan.create!(manufacturer: mfr, factory: decatur, series: 'Aspire', name: 'Belvidere', slug: 'belvidere')
    variant = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, series: 'Aspire', model_number: '2856H32392',
                                         width_ft: 28, length_ft: 56, media: { 'photos' => [{ 'url' => photo }], 'trueview_photos' => { 'kitchen' => [photo] } })
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 90_000)
    group = CatalogOptionGroup.create!(manufacturer: mfr, factory: topeka, key: 'kitchen', name: 'Kitchen', position: 3)
    old = CatalogOption.create!(group: group, manufacturer: mfr, key: 'fridge-old', name: '20.5CF O/U Refer w/o Ice')
    fridge = CatalogOption.create!(group: group, manufacturer: mfr, key: 'fridge', name: '21 CF Stnls SxS Refer w/ice', kind: 'upgrade')
    old.update!(replaced_by: fridge)
    CatalogOptionPrice.create!(price_book: book, option: fridge, dealer_cost: 1000, suggested_retail: 1550, variant: variant)
    CatalogOptionPrice.create!(price_book: book, option: old, dealer_cost: 0, is_standard: true, series: 'Aspire')
    book.standard_features.create!(series: 'Aspire', category: 'Kitchen', name: 'Shaker cabinets')
    CatalogOptionDecision.create!(manufacturer: mfr, option_key: 'fridge', kind: 'family', value: 'refrigerator', catalog_price_book: book)
  end

  def wipe!
    [CatalogOptionDecision, CatalogOptionPrice, CatalogVariantPrice, CatalogStandardFeature].each { |k| k.delete_all }
    CatalogOption.update_all(replaced_by_id: nil)
    [CatalogOption, CatalogOptionGroup, CatalogPlanVariant, CatalogPlan, CatalogPriceBook, Factory].each { |k| k.delete_all }
  end

  it 'copies the book whole, by name and model number, keeping every option name; a second copy changes nothing' do
    row = JSON.parse(described_class.export(book).to_json)
    wipe!

    expect(described_class.import!(row)).to eq(:created)
    copy = CatalogPriceBook.sole
    expect(copy).to have_attributes(name: 'Topeka 2026', status: 'published', factory: have_attributes(state: 'KS'))
    expect(copy.published_at).to eq(Time.zone.parse('2026-09-01'))
    variant = CatalogPlanVariant.sole
    expect(variant.catalog_plan.factory.name).to eq('Decatur')
    expect(variant.media['trueview_photos']).to eq('kitchen' => [photo])
    expect(copy.variant_prices.sole).to have_attributes(variant: variant, net_base_price: 90_000)
    fridge = CatalogOption.find_by(key: 'fridge')
    expect(fridge).to have_attributes(name: '21 CF Stnls SxS Refer w/ice', group: have_attributes(key: 'kitchen'))
    expect(CatalogOption.find_by(key: 'fridge-old').replaced_by).to eq(fridge)
    expect(copy.option_prices.map { |p| [p.option.key, p.variant&.model_number, p.series] })
      .to contain_exactly(['fridge', '2856H32392', nil], ['fridge-old', nil, 'Aspire'])
    expect(copy.standard_features.sole.name).to eq('Shaker cabinets')
    expect(CatalogOptionDecision.sole).to have_attributes(option_key: 'fridge', catalog_price_book_id: copy.id)

    # Run again after a decision was changed here: nothing doubles, and the
    # local decision stands.
    CatalogOptionDecision.sole.update!(value: 'kept-here')
    expect(described_class.import!(row)).to eq(:updated)
    expect([CatalogPriceBook.count, CatalogOptionPrice.count, CatalogVariantPrice.count, CatalogOption.count]).to eq([1, 2, 1, 2])
    expect(CatalogOptionDecision.sole.value).to eq('kept-here')
  end

  it 'leaves a different published book for the factory alone' do
    row = JSON.parse(described_class.export(book).to_json)
    book.update!(name: 'Topeka 2025')
    expect(described_class.import!(row)).to include('Topeka 2025 is already the published book')
    expect(CatalogPriceBook.count).to eq(1)
  end
end
