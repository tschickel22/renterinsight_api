# frozen_string_literal: true

require 'rails_helper'

# Converting a lead who saved a design: the deal's Deal Sheet starts from that
# design, so the buyer's options and colors are on it, rather than waiting for
# a rep to pick the right one of two "Start from" buttons.
RSpec.describe Truebuild::ConversionCarry do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen') }
  let(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:contact) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: contact.id, stage: 'prospecting') }

  def option(name, kind:, retail:, **meta)
    opt = CatalogOption.create!(group: group, manufacturer: mfr, key: "kitchen--#{name.parameterize}", name: name, kind: kind, metadata: meta)
    CatalogOptionPrice.create!(price_book: book, option: opt, dealer_cost: retail / 2, suggested_retail: retail)
    opt
  end

  let(:hardware) { option('Ozark Cabs IPO HW', kind: 'swap', retail: 1216.75) }
  let(:white) { option('Destin White', kind: 'color', retail: 0, color_set: 'Cabinets') }

  before { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645) }

  def design(option_ids)
    company.truebuild_designs.create!(variant: variant, option_ids: option_ids, name: 'Apex (2856H32P01)', lead_id: lead.id,
                                      buyer_email: 'pat@example.com', buyer_name: 'Pat Smith', price_snapshot: {})
  end

  it "starts the deal's LIVE Deal Sheet from the newest design, with its options and colors" do
    design([hardware.id])
    newest = design([hardware.id, white.id])

    described_class.call(lead: lead, contact: contact, account: nil, deal: deal)

    build = deal.reload.home_build
    expect(build).to have_attributes(live: true, version_number: 1, truebuild_design_id: newest.id)
    expect(build.lines.where(kind: 'option').pluck(:catalog_option_id)).to contain_exactly(hardware.id, white.id)
    expect(build.lines.find_by(catalog_option_id: white.id).label).to eq('Cabinets: Destin White')
  end

  it 'leaves a deal that already has a Deal Sheet alone' do
    Truebuild::DealBuild.start(deal: deal, variant: variant)
    design([hardware.id])

    described_class.call(lead: lead, contact: contact, account: nil, deal: deal)

    expect(deal.home_builds.count).to eq(1)
    expect(deal.home_build.lines.where(kind: 'option')).to be_empty
  end

  it 'still converts when the sheet cannot be started' do
    saved = design([hardware.id])
    allow(Truebuild::DealBuild).to receive(:start).and_raise(ActiveRecord::RecordInvalid)

    expect(described_class.call(lead: lead, contact: contact, account: nil, deal: deal)).to eq(1)
    expect(saved.reload.deal_id).to eq(deal.id)
    expect(deal.home_builds).to be_empty
  end
end
