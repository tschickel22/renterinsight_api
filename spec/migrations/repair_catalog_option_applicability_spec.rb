# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260930233000_repair_catalog_option_applicability')

RSpec.describe RepairCatalogOptionApplicability do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'construction', name: 'Construction') }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'exterior', name: 'Exterior') }

  before { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }

  def item(description, cell, tab: '2025 Aspire SW', section: 'Drywall')
    book.import_items.create!(item_type: 'option_price', review_status: 'approved',
                              source_ref: { 'sheet' => tab, 'cells' => [cell] },
                              payload: { 'tab' => tab, 'section' => section, 'description' => description,
                                         'applies_to' => { 'width_ft' => 60, 'box_length_max_ft' => 60 } })
  end

  it 'splits options merged by a comparison, sets series and bands, and leaves colors alone' do
    merged = CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--drywall-t-o-sw-60-box', name: "Drywall T/O SW >60' box")
    small = CatalogOptionPrice.create!(price_book: book, option: merged, dealer_cost: 4155, width_ft: 60, max_length_ft: 60,
                                       section_type: 'single', source_ref: item("Drywall T/O SW<=60' box", 'F88').source_ref)
    big = CatalogOptionPrice.create!(price_book: book, option: merged, dealer_cost: 4455, min_length_ft: 61,
                                     source_ref: item("Drywall T/O SW >60' box", 'F89').source_ref)
    white = CatalogOption.create!(group: exterior, manufacturer: mfr, key: 'exterior--white', name: 'White', kind: 'color')
    color = CatalogOptionPrice.create!(price_book: book, option: white, is_standard: true, source_ref: { 'sheet' => '2025 Aspire SW' })
    book.import_items.create!(item_type: 'option_price', review_status: 'approved', source_ref: { 'sheet' => '2025 Aspire SW' },
                              payload: { 'tab' => '2025 Aspire SW', 'section' => 'Exterior', 'description' => '3 Tab Shingles' })

    described_class.new.up
    described_class.new.up # idempotent

    expect(small.reload.option.name).to eq("Drywall T/O SW<=60' box")
    expect(small).to have_attributes(series: 'Aspire', section_type: 'single', width_ft: nil, max_length_ft: 60)
    expect(big.reload.option.name).to eq("Drywall T/O SW >60' box")
    expect(big).to have_attributes(series: 'Aspire', min_length_ft: 61, max_length_ft: nil)
    expect(small.option).not_to eq(big.option)
    expect(CatalogOption.exists?(merged.id)).to be(false)
    expect(color.reload).to have_attributes(catalog_option_id: white.id, series: nil)
  end
end
