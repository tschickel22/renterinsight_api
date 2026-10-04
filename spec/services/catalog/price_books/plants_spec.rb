# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::PriceBooks::Plants do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let!(:topeka) { mfr.factories.create!(name: 'Topeka, Dutch Housing', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: 'Topeka 2026', status: 'published', published_at: 1.day.ago) }

  it 'does not match a plant on generic words like factory or homes' do
    mfr.factories.create!(name: 'Meridian Factory', code: 'MER')
    mfr.factories.create!(name: 'Champion Homes - Benton', code: 'BEN')
    expect(described_class.detect('Prime - Decatur factory', mfr)).to be_nil
    expect(described_class.detect('Homes options', mfr)).to be_nil
    expect(described_class.detect('Benton specials', mfr).name).to eq('Champion Homes - Benton')
  end

  it 'finds a known plant by name, adds one a tab names plainly, and ignores tabs naming none' do
    expect(described_class.detect('Topeka specials', mfr)).to eq(topeka)
    expect(described_class.detect('Prime - Decatur factory', mfr)).to be_nil # finding only, unless publishing
    decatur = described_class.detect('Prime - Decatur factory', mfr, create: true)
    expect(decatur).to have_attributes(name: 'Decatur', manufacturer_id: mfr.id)
    expect(described_class.detect('Prime - Decatur factory', mfr)).to eq(decatur)
    expect(described_class.detect('2025 Aspire DW', mfr)).to be_nil
    expect(described_class.detect('Base Factory Options', mfr, create: true)).to be_nil
  end

  it "labels a series with the plant its tab names, and the model stays priced by its book" do
    prime = CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Prime Of Indiana', name: 'P01')
    aspire = CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Aspire', name: 'Lincoln')
    variant = CatalogPlanVariant.create!(catalog_plan: prime, manufacturer: mfr, model_number: '1676H32P01')
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 50_000)
    book.documents.create!(filename: 'options.xlsx', checksum_sha256: SecureRandom.hex(16), kind: 'order_form',
                           metadata: { 'tab_list' => [{ 'name' => 'Prime - Decatur factory' }, { 'name' => '2025 Aspire DW' }] })

    applied = described_class.label_series(book)
    decatur = mfr.factories.find_by!(name: 'Decatur')
    expect(applied).to eq('Prime Of Indiana' => decatur.id)
    expect(prime.reload.factory).to eq(decatur)
    expect(aspire.reload.factory).to eq(topeka)
    expect(Truebuild::BookResolver.current_for(variant.reload)).to eq(book)
  end

  it 'prices a model from the newest book that has a price for it' do
    plan = CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Prime Of Indiana', name: 'P01')
    variant = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '1676H32P01')
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 50_000)
    decatur = mfr.factories.create!(name: 'Decatur', code: 'DEC')
    later = CatalogPriceBook.create!(manufacturer: mfr, factory: decatur, name: 'Decatur 2027', status: 'published', published_at: Time.current)
    expect(Truebuild::BookResolver.current_for(variant)).to eq(book)

    CatalogVariantPrice.create!(price_book: later, variant: variant, net_base_price: 52_000)
    expect(Truebuild::BookResolver.current_for(variant)).to eq(later)
  end
end
