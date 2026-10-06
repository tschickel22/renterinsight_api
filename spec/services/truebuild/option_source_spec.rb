# frozen_string_literal: true

require 'rails_helper'

# Decatur's Prime homes are priced by the Topeka package, which also carried
# Prime options from a December workbook. Decatur's February order form is a
# book of options alone. The newest book wins for what it covers.
RSpec.describe Truebuild::OptionSource do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:decatur) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:prime_plan) { CatalogPlan.create!(manufacturer: mfr, factory: decatur, series: 'Prime Of Indiana', name: 'Apex') }
  let(:aspire_plan) { CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Aspire', name: 'Belvidere') }
  let(:prime) { CatalogPlanVariant.create!(catalog_plan: prime_plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:aspire) { CatalogPlanVariant.create!(catalog_plan: aspire_plan, manufacturer: mfr, model_number: '2856M32392', width_ft: 28, length_ft: 56) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'exterior', name: 'Exterior') }
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }

  let!(:package) do
    CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: 'Topeka package 2026', status: 'published', published_at: 2.days.ago)
  end

  def option(name)
    CatalogOption.create!(group: group, manufacturer: mfr, key: "exterior--#{name.parameterize}", name: name)
  end

  def row(book, opt, cost, **applies)
    CatalogOptionPrice.create!(price_book: book, option: opt, dealer_cost: cost, **applies)
  end

  let(:old_wrap) { option("OSB Wrap Sectional") }
  let(:new_wrap) { option("OSB Wrap (>=56) SECTIONAL") }
  let(:aspire_wrap) { option('Aspire OSB Wrap') }

  before do
    CatalogVariantPrice.create!(price_book: package, variant: prime, net_base_price: 49_645)
    CatalogVariantPrice.create!(price_book: package, variant: aspire, net_base_price: 57_995)
    row(package, old_wrap, 990, series: 'Prime Of Indiana')
    row(package, aspire_wrap, 875, series: 'Aspire')
  end

  def publish_form
    CatalogPriceBook.create!(manufacturer: mfr, factory: decatur, name: 'Decatur Prime options 2026',
                             status: 'published', published_at: 1.hour.ago).tap { |b| row(b, new_wrap, 500) }
  end

  def offered_names(variant)
    described_class.offered(described_class.current_for(variant), variant).map { |op| op.option.name }
  end

  it 'takes options from the book that prices the base when nothing newer covers the model' do
    expect(described_class.current_for(prime)).to eq(package)
    expect(offered_names(prime)).to eq(['OSB Wrap Sectional'])
  end

  it "lets a plant's options-only book replace the older rows, without merging and without touching other plants" do
    form = publish_form

    expect(described_class.current_for(prime)).to eq(form)
    expect(offered_names(prime)).to eq(['OSB Wrap (>=56) SECTIONAL'])
    # The base still comes from the package, which is the only book pricing it.
    expect(Truebuild::BookResolver.current_for(prime)).to eq(package)
    # Aspire is Topeka's: the Decatur sheet says nothing about it.
    expect(described_class.current_for(aspire)).to eq(package)
    expect(offered_names(aspire)).to eq(['Aspire OSB Wrap'])
  end

  it 'prices options from the options book while the base keeps its own book' do
    form = publish_form
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.3)

    r = Truebuild::PricingEngine.new(company: company, variant: prime, option_ids: [new_wrap.id, old_wrap.id]).call
    expect(r.cost_book).to eq(package)
    expect(r.options_book).to eq(form)
    expect(r.lines.select { |l| l[:kind] == 'option' }.map { |l| [l[:label], l[:cost]] }).to eq([['OSB Wrap (>=56) SECTIONAL', 500.0]])
    expect(r.warnings).to include("OSB Wrap Sectional is not offered on #{prime.model_number}.")
  end

  it 'holds option retail on the earlier book while a reviewing dealer has not accepted the new sheet' do
    form = publish_form
    company.dealer_catalog_terms.create!(price_update_policy: 'review')
    company.dealer_price_book_adoptions.create!(price_book: form, status: 'pending')

    expect(described_class.book_for(company, prime)).to eq(package)

    company.dealer_price_book_adoptions.find_by(price_book: form).update!(status: 'adopted')
    expect(described_class.book_for(company, prime)).to eq(form)
  end
end
