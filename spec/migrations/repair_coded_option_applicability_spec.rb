# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260930234000_repair_coded_option_applicability')

RSpec.describe RepairCodedOptionApplicability do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'other', name: 'Other Options') }

  def row(name, **attrs)
    opt = CatalogOption.create!(group: group, manufacturer: mfr, key: "other--#{name.parameterize}", name: name)
    CatalogOptionPrice.create!(price_book: book, option: opt, dealer_cost: 100, **attrs)
  end

  it 'fills section and length from the name without overwriting what a row has' do
    sect = row('Ash Trim IPO 618 Ceiling, Window, and Door - T/O - Sect (***VOG***)')
    sw = row("5\" White Crown in Kitchen and Living Room (SW ONLY)")
    kept = row('Trim - Sect', section_type: 'single')
    band = row("Red Board Wrap >=70' SW")

    described_class.new.up

    expect(sect.reload.section_type).to eq('multi')
    expect(sw.reload.section_type).to eq('single')
    expect(kept.reload.section_type).to eq('single')
    expect(band.reload).to have_attributes(section_type: 'single', min_length_ft: 70, max_length_ft: nil)
  end
end
