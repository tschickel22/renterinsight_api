# frozen_string_literal: true

require 'rails_helper'

# A buyer with an open deal saves a design on the website: it reaches the deal
# as a new draft Deal Sheet version (never the LIVE one) with a notice to the
# rep, or, when the deal has no sheet yet, attached so the sheet can start
# from it.
RSpec.describe Truebuild::DesignToDeal do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'Pat@Example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id, owner_id: rep.id, stage: 'proposal') }

  before { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645) }

  def design
    company.truebuild_designs.create!(variant: variant, option_ids: [], name: 'Apex (2856H32P01)', buyer_email: 'pat@example.com',
                                      buyer_name: 'Pat Smith', price_snapshot: {})
  end

  it 'adds a draft version to a deal that has a Deal Sheet, and tells the rep' do
    Truebuild::DealBuild.start(deal: deal, variant: variant)
    saved = design
    build = described_class.call(saved)

    expect(build).to have_attributes(live: false, version_number: 2, truebuild_design_id: saved.id)
    expect(build.label).to start_with("From the buyer's design")
    expect(deal.home_build.version_number).to eq(1) # the LIVE version is untouched
    expect(saved.reload.deal_id).to eq(deal.id)
    expect(Notification.where(recipient: rep, notification_type: 'deal_sheet_buyer_design').count).to eq(1)

    expect(described_class.call(saved)).to be_nil # once only
  end

  it 'attaches the design to a deal with no sheet yet, and leaves closed deals alone' do
    deal
    saved = design
    expect(described_class.call(saved)).to eq(deal)
    expect(deal.home_builds).to be_empty
    expect(saved.reload.deal_id).to eq(deal.id)

    deal.update_columns(stage: 'closed_won')
    expect(described_class.call(design)).to be_nil
  end
end
