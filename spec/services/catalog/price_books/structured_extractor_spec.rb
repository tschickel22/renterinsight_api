# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

# A structured catalog file (Factory Direct's quote desk export of Champion
# Decatur): read with no model, reconciled, reviewed and published like any
# other book, keeping the catalog's own plan names.
RSpec.describe Catalog::PriceBooks::StructuredExtractor do
  let!(:s3) { stub_private_files }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_housing') }
  let(:decatur) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}", city: 'Decatur', state: 'IN') }
  let(:company) { Company.create!(name: "Platform #{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!', first_name: 'P', last_name: 'A',
                 company_id: company.id, role: 'platform_admin')
  end
  let!(:peak) do
    plan = CatalogPlan.create!(manufacturer: mfr, factory: decatur, series: 'Prime Of Indiana', name: 'Peak')
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, series: 'Prime Of Indiana', model_number: '1456H22P01', width_ft: 14, length_ft: 56)
  end
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: decatur, name: 'Decatur Prime 2026', created_by: admin) }

  let(:file) do
    { format: 'catalog.v1', partial: true, source: 'Factory Direct quote desk',
      homes: [{ model_number: '1456H22P01', model_name: 'PEAK', series: 'Prime', plant: 'Decatur', width_ft: 14, length_ft: 56,
                beds: 2, baths: 2, net_base_price: 30_195 },
              { model_number: '1636H11P01', model_name: 'PIKE', series: 'Prime', plant: 'Decatur', width_ft: 16, length_ft: 36,
                beds: 1, baths: 1, net_base_price: 26_000 }],
      options: [{ tab: 'Prime - Decatur factory', section: 'Exterior', description: 'Sliding Glass Door', dealer_cost: 795 },
                { tab: 'Prime - Decatur factory', section: 'Construction',
                  description: 'Upgrade Insulation: R33 Roof & R22 Outside I-Beams Singlewide', dealer_cost: 330 }],
      colors: [{ tab: 'Prime - Decatur factory', group: 'Siding', name: 'Clay' },
               { tab: 'Prime - Decatur factory', group: 'Siding', name: 'Flint' },
               { tab: 'Prime - Decatur factory', group: 'Siding', name: 'White' },
               { tab: 'Prime - Decatur factory', group: 'Shutters', name: 'White' },
               { tab: 'Prime - Decatur factory', group: 'Corner Posts', name: 'White' }] }.to_json
  end

  it 'is recognized, reads every row, and publishes them under the catalog names' do
    expect(described_class.structured?('decatur.json', file)).to be(true)
    expect(described_class.structured?('notes.json', '{"a":1}')).to be(false)
    expect(Catalog::PriceBooks::Classifier.guess('decatur.json', file)).to eq('price_list')

    doc = book.documents.create!(filename: 'decatur.json', checksum_sha256: SecureRandom.hex(32), kind: 'price_list',
                                 storage_key: 'k', storage_bucket: 'b', byte_size: file.bytesize, content_type: 'application/json')
    described_class.new(doc, file, Catalog::PriceBooks::Recorder.new(book, document: doc)).call
    expect(book.import_items.group(:item_type).count).to eq('variant_price' => 2, 'option_price' => 2, 'option' => 5)
    expect(doc.reload.metadata).to include('structured' => true, 'partial' => true)

    Catalog::PriceBooks::Reconciler.new(book).call
    book.import_items.update_all(review_status: 'approved')
    Catalog::PriceBooks::Publisher.new(book, by: admin).call

    # Peak keeps its plan; Pike, new, gets a plan in the Prime series.
    expect(peak.reload.catalog_plan.name).to eq('Peak')
    expect(peak.variant_prices.find_by(price_book: book).net_base_price).to eq(30_195)
    pike = CatalogPlanVariant.find_by!(manufacturer: mfr, model_number: '1636H11P01')
    expect(pike.variant_prices.first.net_base_price).to eq(26_000)

    rows = book.option_prices.includes(:option).to_a
    door = rows.find { |r| r.option.name == 'Sliding Glass Door' }
    expect(door).to have_attributes(dealer_cost: 795, series: 'Prime Of Indiana')
    insulation = rows.find { |r| r.option.name.start_with?('Upgrade Insulation') }
    expect(insulation.section_type).to eq('single')
    clay = rows.find { |r| r.option.name == 'Clay' }
    expect(clay.option.metadata['color_set']).to be_present
    expect(clay.is_standard).to be(true)
    # "White" in three sets is three options, each in its own set.
    whites = rows.select { |r| r.option.name == 'White' }
    expect(whites.map { |r| r.option.metadata['color_set'] }).to contain_exactly('Siding', 'Shutters', 'Corner posts')
    expect(whites.map(&:catalog_option_id).uniq.size).to eq(3)
  end

  it 'splits colors a book published before keying by set had sharing one option' do
    shared = CatalogOption.create!(manufacturer: mfr, key: 'exterior--white', name: 'White', kind: 'color',
                                   group: CatalogOptionGroup.create!(manufacturer: mfr, key: 'exterior', name: 'Exterior'),
                                   metadata: { 'color_set' => 'Shutters' })
    book.update_columns(status: 'published', published_at: Time.current)
    %w[Siding Shutters].each_with_index do |set, i|
      ref = { 'document_id' => 1, 'structured' => 'color', 'index' => i }
      book.import_items.create!(item_type: 'option', review_status: 'approved', source_ref: ref,
                                payload: { 'kind' => 'color', 'group' => set, 'name' => 'White' })
      CatalogOptionPrice.create!(price_book: book, option: shared, is_standard: true, source_ref: ref)
    end
    expect(Catalog::PriceBooks::Publisher.split_colors!(book)).to eq(2)
    sets = book.option_prices.reload.map { |r| r.option.metadata['color_set'] }
    expect(sets).to contain_exactly('Siding', 'Shutters')
    expect(Catalog::PriceBooks::Publisher.split_colors!(book)).to eq(0) # once is enough
  end
end
