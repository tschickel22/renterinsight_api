# frozen_string_literal: true

require 'rails_helper'

# A dealer's agreement package rendered for one deal: Factory Direct's
# contract in their wording, filled from the deal and its Deal Sheet, with
# Schedule A and the Colors sheet in place of their own option and color
# pages; every signature, initial and date measured as a signing field, and
# every blank we cannot know left as a field for the rep.
RSpec.describe Agreements::PacketRenderer do
  let(:packet) { JSON.parse(File.read(Rails.root.join('script/agreement_templates/fdhc_indiana_packet.json'))) }
  let(:company) { Company.create!(name: "Factory Direct #{SecureRandom.hex(3)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:template) { company.agreement_templates.create!(name: 'Factory Direct Purchase Agreement (Indiana)', status: 'active', template_type: 'upload', packet: packet) }
  let(:mfr) { Manufacturer.create!(name: 'Champion Home Builders', industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56, beds: 3, baths: 2, square_feet: 1493) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let(:rep) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com', phone: '260-555-0100', street: '1 Main St', city: 'Auburn', state: 'IN', zip: '46706') }
  let(:co_buyer) { company.contacts.create!(first_name: 'Sam', last_name: 'Smith', email: 'sam@example.com', phone: '260-555-0101') }
  let(:deal) do
    company.deals.create!(name: 'Smith Bay Port', contact_id: buyer.id, co_applicant_contact_id: co_buyer.id, owner_id: rep.id,
                          delivery_street: '9 Farm Rd', delivery_city: 'Garrett', delivery_state: 'IN', delivery_zip: '46738')
  end

  def pdf_pages(data) = PDF::Reader.new(StringIO.new(data)).pages.map(&:text)

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    insulation = CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--insulation', name: 'Upgrade Insulation', kind: 'upgrade', factory_code: 'INS38')
    CatalogOptionPrice.create!(price_book: book, option: insulation, dealer_cost: 1295)
    build = Truebuild::DealBuild.start(deal: deal, variant: variant)
    build.add_option(insulation.id)
    DealSaleDetails.new(deal).update!('payment_type' => 'cash', 'site_ownership' => 'Buyer owns the land', 'county' => 'DeKalb',
                                      'contingency' => 'Subject to financing approval', 'contingency_deadline' => '2026-11-15',
                                      'contingency_description' => 'Buyer to provide bank letter', 'payment_method' => 'Wire transfer',
                                      'balance_due_by' => '2027-01-15', 'model_year' => '2026')
  end

  it "fills Factory Direct's contract from the deal and puts our sheets in their place" do
    result = described_class.new(deal.reload, template, agreement_number: 'PA-1001', date: Date.new(2026, 10, 9)).call
    pages = pdf_pages(result.pdf)
    expect(result.page_count).to eq(pages.size)

    first = pages.first(2).join("\n")
    expect(first).to include('Manufactured Home Purchase Agreement', 'PA-1001', '10/09/2026', 'Rita Rep', 'Pat Smith', 'Sam Smith',
                             '1 Main St', '9 Farm Rd', 'DeKalb', 'Buyer owns the land', 'Champion Home Builders', 'Topeka, IN',
                             'NEW', '28 x 56', '1493', 'CASH', 'Subject to financing approval', '11/15/2026', 'Buyer to provide bank letter',
                             '01/15/2027')
    sheets = Truebuild::AgreementSheets.new(deal.home_build)
    expect(first).to include(Agreements::PacketValues.money(sheets.base_price))
    expect(first).to include(Agreements::PacketValues.money(deal.home_build.totals['contract_total']))

    all = pages.join("\n")
    expect(all).to include('Addendum “A”: Options, Upgrades and Specifications', 'Color and Finish Selections', 'Terms and Conditions of Sale')
    expect(all).not_to include('Dealer working copy') # the dealer's tax worksheet stays out
    expect(all).not_to include('$1,295.00') # dealer cost never prints

    signer = result.placements.select { |p| p['isSignerField'] }
    expect(result.signers).to eq(%w[buyer_1 rep manager buyer_2])
    expect(signer.map { |p| p['signerIndex'] }.uniq).to contain_exactly(0, 1, 2, 3)
    expect(signer.select { |p| p['fieldType'] == 'initials' }.size).to be > 20
    expect(result.placements).to all(include('x' => be_between(0, 100), 'y' => be_between(0, 100), 'page' => be_between(0, pages.size - 1)))

    keys = result.definitions.map { |d| d['key'] }
    expect(keys).to include('page1_f40', 'page1_f44', 'build_furnace') # roof load, hitch, an appliance choice: the rep's
    expect(keys).not_to include('page1_f21', 'page1_dealtype')
    furnace = result.definitions.find { |d| d['key'] == 'build_furnace' }
    expect(furnace['options']).to eq(%w[YES NO N/A])
  end

  it 'leaves Buyer 2 out when the deal has one buyer' do
    deal.update!(co_applicant_contact_id: nil)
    result = described_class.new(deal.reload, template).call
    expect(result.signers).to eq(%w[buyer_1 rep manager])
    expect(result.placements.select { |p| p['isSignerField'] }.map { |p| p['signerIndex'] }.uniq).to contain_exactly(0, 1, 2)
  end
end
