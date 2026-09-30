# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::PriceBookNotifier do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856M32392', width_ft: 28, length_ft: 56) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen') }
  let(:knobs) { CatalogOption.create!(group: group, manufacturer: mfr, key: 'kitchen--knobs', name: 'Cabinet Knobs') }
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let!(:admin) do
    User.create!(company: company, email: "a#{SecureRandom.hex(3)}@example.com", password: 'Password123!',
                 first_name: 'Ada', last_name: 'Admin', role: 'company_admin', status: 'active')
  end
  let(:old_book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }

  before do
    CatalogVariantPrice.create!(price_book: old_book, variant: variant, net_base_price: 60_000)
    CatalogOptionPrice.create!(price_book: old_book, option: knobs, dealer_cost: 65)
    CatalogStandardFeature.create!(price_book: old_book, series: 'Aspire', category: 'Kitchen', name: 'Shaker cabinets')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.25)
  end

  def publish_new(base: 63_000, knobs_cost: 70)
    book = CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2027', status: 'in_review')
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: base)
    CatalogOptionPrice.create!(price_book: book, option: knobs, dealer_cost: knobs_cost)
    CatalogStandardFeature.create!(price_book: book, series: 'Aspire', category: 'Kitchen', name: 'Shaker cabinets')
    CatalogStandardFeature.create!(price_book: book, series: 'Aspire', category: 'Kitchen', name: 'Soft close drawers')
    CatalogPriceBook.transaction do
      book.publish!(by: User.new(role: 'platform_admin'))
      described_class.hold_for_review(book)
    end
    book
  end

  it 'holds a reviewing dealer on their old prices until they accept, and tells their admins what moved' do
    company.dealer_catalog_terms.create!(price_update_policy: 'review')
    book = publish_new

    expect(Truebuild::BookResolver.book_for(company, variant)).to eq(old_book)
    # Cost follows the factory now; retail stays marked up from the accepted book.
    held = Truebuild::PricingEngine.new(company: company, variant: variant, option_ids: [knobs.id]).call
    expect(held.lines.first).to include(cost: 63_000.0, retail: 75_000.0)
    expect(held.lines.last).to include(cost: 70.0, retail: 81.25)
    expect(held.warnings.first).to start_with('Your prices are still based on Topeka 2026, but costs follow Topeka 2027.')
    described_class.deliver(book)

    adoption = company.dealer_price_book_adoptions.find_by!(price_book: book)
    expect(adoption).to have_attributes(status: 'pending', previous_book_id: old_book.id)
    homes = adoption.summary['homes']
    expect(homes).to include('changed' => 1, 'up' => 1, 'avg_pct' => 5.0)
    expect(homes['rows'].first).to include('old_cost' => 60_000.0, 'new_cost' => 63_000.0, 'old_retail' => 75_000.0, 'new_retail' => 78_750.0)
    expect(adoption.summary['options']['rows'].first).to include('label' => 'Cabinet Knobs', 'cost_change' => 5.0)
    expect(adoption.summary['features']['added']).to eq([{ 'series' => 'Aspire', 'name' => 'Soft close drawers' }])

    note = Notification.find_by!(recipient: admin, notification_type: 'truebuild_price_update')
    expect(note.title).to eq("New #{mfr.name} prices to review")
    expect(note.message).to eq('1 home changed price (average +5.0%), 1 option price changed, 1 new standard feature. ' \
                               'Your prices stay the same until you accept.')

    adoption.update!(status: 'adopted')
    expect(Truebuild::BookResolver.book_for(company, variant)).to eq(book)
  end

  it 'adopts right away for dealers on automatic updates, and for feature-only books' do
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    reviewer = Company.create!(name: "Reviewer #{SecureRandom.hex(3)}")
    reviewer.dealer_catalog_terms.create!(price_update_policy: 'review')

    book = publish_new
    described_class.deliver(book)
    expect(company.dealer_price_book_adoptions.find_by!(price_book: book).status).to eq('adopted')
    expect(reviewer.dealer_price_book_adoptions.find_by!(price_book: book).status).to eq('pending')

    reviewer.dealer_price_book_adoptions.update_all(status: 'adopted')
    same = publish_new # same prices, same features: nothing to decide
    described_class.deliver(same)
    expect(reviewer.dealer_price_book_adoptions.find_by!(price_book: same)).to have_attributes(status: 'adopted')
    expect(reviewer.dealer_price_book_adoptions.find_by!(price_book: same).summary['features_only']).to be(true)
  end

  it 'marks an undecided older update superseded when a newer book arrives' do
    company.dealer_catalog_terms.create!(price_update_policy: 'review')
    first = publish_new
    second = publish_new(base: 64_000)

    expect(company.dealer_price_book_adoptions.find_by!(price_book: first).status).to eq('superseded')
    expect(company.dealer_price_book_adoptions.find_by!(price_book: second)).to have_attributes(status: 'pending', previous_book_id: old_book.id)
  end

  it 'skips companies that do not price with TrueBuild' do
    bystander = Company.create!(name: "Bystander #{SecureRandom.hex(3)}")
    publish_new
    expect(bystander.dealer_price_book_adoptions).to be_empty
  end
end
