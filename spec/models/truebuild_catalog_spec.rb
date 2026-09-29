# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'TrueBuild catalog models' do
  let(:manufacturer) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_housing') }
  let(:factory) { manufacturer.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}", state: 'IN') }
  let(:plan) { CatalogPlan.create!(manufacturer: manufacturer, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", password: 'password123',
                 first_name: 'P', last_name: 'A', company_id: company.id, role: 'platform_admin')
  end
  let(:dealer_user) do
    User.create!(email: "du-#{SecureRandom.hex(4)}@example.com", password: 'password123',
                 first_name: 'D', last_name: 'U', company_id: company.id)
  end

  def variant(number, **attrs)
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: manufacturer, model_number: number,
                               width_ft: 28, length_ft: 56, beds: 3, baths: 2, **attrs)
  end

  def book(**attrs)
    CatalogPriceBook.create!(manufacturer: manufacturer, factory: factory, name: 'Topeka 2026', **attrs)
  end

  describe CatalogPlan do
    it 'slugs its name and is unique per manufacturer and series' do
      expect(plan.slug).to eq('belvidere')
      dup = CatalogPlan.new(manufacturer: manufacturer, series: 'Aspire', name: 'Belvidere')
      expect(dup).not_to be_valid
    end
  end

  describe CatalogPlanVariant do
    it 'normalizes the model number, keeps the printed one, and infers the code' do
      v = variant('2856h32po1')

      expect(v.model_number).to eq('2856H32P01')
      expect(v.model_number_as_printed).to eq('2856h32po1')
      expect(v.building_code).to eq('HUD')
    end

    it 'treats O and 0 spellings as the same model' do
      variant('2856H32PO1')
      expect(CatalogPlanVariant.new(catalog_plan: plan, manufacturer: manufacturer, model_number: '2856H32P01'))
        .not_to be_valid
    end

    it 'must share its plan manufacturer' do
      other = Manufacturer.create!(name: "Other #{SecureRandom.hex(3)}", industry_type: 'manufactured_housing')
      v = CatalogPlanVariant.new(catalog_plan: plan, manufacturer: other, model_number: '2856H32392')
      expect(v).not_to be_valid
      expect(v.errors[:manufacturer_id]).to be_present
    end
  end

  describe CatalogPriceBook do
    it 'publishes, superseding the previous book for the same plant' do
      old = book
      old.publish!(by: admin)
      new_book = book(name: 'Topeka 2026 rev')
      new_book.publish!(by: admin)

      expect(old.reload.status).to eq('superseded')
      expect(new_book.reload).to have_attributes(status: 'published', published_by_id: admin.id, supersedes_id: old.id)
      expect(CatalogPriceBook.current_for(manufacturer_id: manufacturer.id, factory_id: factory.id)).to eq(new_book)
    end

    it 'refuses a publisher who is not a platform admin' do
      expect { book.publish!(by: dealer_user) }.to raise_error(ArgumentError, /platform admin/)
    end

    it 'cannot publish a book twice' do
      b = book
      b.publish!(by: admin)
      expect { b.publish!(by: admin) }.to raise_error(ActiveRecord::RecordInvalid, /not ready to publish/)
    end

    it 'allows only one published book per plant at the database level' do
      book(status: 'published')
      expect { book(name: 'Second', status: 'published') }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'rejects a plant from another manufacturer' do
      other = Manufacturer.create!(name: "Other #{SecureRandom.hex(3)}", industry_type: 'manufactured_housing')
      b = CatalogPriceBook.new(manufacturer: other, factory: factory, name: 'X')
      expect(b).not_to be_valid
    end
  end

  describe CatalogPriceBookDocument do
    it 'will not take the same file twice in one book' do
      b = book
      b.documents.create!(filename: 'a.pdf', checksum_sha256: 'abc')
      expect(b.documents.new(filename: 'copy.pdf', checksum_sha256: 'abc')).not_to be_valid
    end
  end

  describe CatalogVariantPrice do
    it 'adds required adders to the net base unless a total is printed' do
      v = variant('2840M32024')
      price = CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 49_075,
                                          required_adders: [{ name: 'MOD Conversion', amount: 3150 },
                                                            { name: 'Drywall', amount: 4460 },
                                                            { name: 'Water Heater Door', amount: 135 },
                                                            { name: 'CO Detector', amount: 260 }])
      expect(price.required_adders.first.keys).to all(be_a(String))
      expect(price.base_cost).to eq(57_080)

      price.update!(total_base_price: 57_000)
      expect(price.base_cost).to eq(57_000)
    end
  end

  describe CatalogOptionPrice do
    let(:group) { CatalogOptionGroup.create!(manufacturer: manufacturer, factory: factory, key: 'drywall', name: 'Drywall') }
    let(:option) { CatalogOption.create!(group: group, manufacturer: manufacturer, key: 'drywall-to', name: 'Drywall T/O') }

    it 'applies by box length band and section type' do
      sectional = variant('2856H32392')
      single = variant('1676H32087', width_ft: 16, length_ft: 76)
      band = CatalogOptionPrice.new(price_book: book, option: option, dealer_cost: 5065,
                                    min_length_ft: 48, max_length_ft: 56, section_type: 'multi')

      expect(band.applies_to?(sectional)).to be(true)
      expect(band.applies_to?(single)).to be(false)
    end

    it 'applies to one model when it names one' do
      target = variant('1456H22P01', width_ft: 14)
      other = variant('1460H22P01', width_ft: 14, length_ft: 60)
      row = CatalogOptionPrice.new(price_book: book, option: option, dealer_cost: 1570, variant: target)

      expect(row.applies_to?(target)).to be(true)
      expect(row.applies_to?(other)).to be(false)
    end

    it 'needs a cost unless the option is standard' do
      expect(CatalogOptionPrice.new(price_book: book, option: option)).not_to be_valid
      expect(CatalogOptionPrice.new(price_book: book, option: option, is_standard: true)).to be_valid
    end
  end

  describe CatalogOptionRule do
    it 'cannot point an option at itself' do
      group = CatalogOptionGroup.create!(manufacturer: manufacturer, key: 'kitchen', name: 'Kitchen')
      island = CatalogOption.create!(group: group, manufacturer: manufacturer, key: 'island', name: 'Island')
      rule = CatalogOptionRule.new(manufacturer: manufacturer, option: island, target_option: island, rule_type: 'excludes')
      expect(rule).not_to be_valid
    end
  end

  describe CatalogImportItem do
    it 'stores JSON with string keys' do
      item = CatalogImportItem.create!(price_book: book, item_type: 'variant_price',
                                       payload: { model_number: '2856H32392', net_base_price: 57_995 },
                                       source_ref: { page: 1 }, flags: [:model_code_beds_mismatch])
      item.reload
      expect(item.payload.keys).to eq(%w[model_number net_base_price])
      expect(item.source_ref).to eq('page' => 1)
      expect(item.flags).to eq(['model_code_beds_mismatch'])
    end
  end

  describe DealerMarkupRule do
    it 'marks up cost four ways' do
      rule = ->(type, value) { DealerMarkupRule.new(markup_type: type, value: value) }
      expect(rule.call('percent', 30).apply(1000)).to eq(1300)
      expect(rule.call('multiplier', 1.55).apply(1000)).to eq(1550)
      expect(rule.call('flat', 2500).apply(1000)).to eq(3500)
      expect(rule.call('manual', 64_900).apply(1000)).to eq(64_900)
    end

    it 'requires the fields its scope needs' do
      rule = company.dealer_markup_rules.new(scope_type: 'series', markup_type: 'multiplier', value: 1.3)
      expect(rule).not_to be_valid
      expect(rule.errors.attribute_names).to include(:manufacturer_id, :scope_value)
    end

    it 'ranks more specific scopes and location rules higher' do
      loc = company.locations.create!(name: "Loc #{SecureRandom.hex(2)}", timezone: 'UTC')
      all = company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.3)
      at_loc = company.dealer_markup_rules.create!(scope_type: 'all', location: loc, markup_type: 'multiplier', value: 1.25)
      plan_rule = company.dealer_markup_rules.create!(scope_type: 'plan', scope_id: plan.id, markup_type: 'manual', value: 64_900)

      expect([all, at_loc, plan_rule].max_by(&:rank)).to eq(plan_rule)
      expect([all, at_loc].max_by(&:rank)).to eq(at_loc)
    end

    it 'rejects a location from another company' do
      other = Company.create!(name: "Other #{SecureRandom.hex(3)}")
      loc = other.locations.create!(name: 'Elsewhere', timezone: 'UTC')
      rule = company.dealer_markup_rules.new(scope_type: 'all', location: loc, markup_type: 'percent', value: 25)
      expect(rule).not_to be_valid
    end
  end

  describe DealerCatalogTerm do
    it 'prefers the manufacturer row, then the company default, then a new default' do
      expect(DealerCatalogTerm.for(company, manufacturer.id)).to have_attributes(new_record?: true, price_display: 'hidden')

      default = company.dealer_catalog_terms.create!(price_display: 'starting_at')
      expect(DealerCatalogTerm.for(company, manufacturer.id)).to eq(default)

      specific = company.dealer_catalog_terms.create!(manufacturer: manufacturer, program_discount_pct: 3, freight_per_mile: 4.5)
      expect(DealerCatalogTerm.for(company, manufacturer.id)).to eq(specific)
    end

    it 'allows one row per company and manufacturer' do
      company.dealer_catalog_terms.create!
      expect(company.dealer_catalog_terms.new).not_to be_valid
    end
  end
end
