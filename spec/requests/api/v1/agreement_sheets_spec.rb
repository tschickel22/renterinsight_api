# frozen_string_literal: true

require 'rails_helper'

# The agreement's standard sheets, from the Deal Sheet: Schedule A lists every
# option at retail (a free color pick is on the Colors sheet instead) and its
# figures add up to the sheet's gross; the Colors sheet lists every set the
# model offers with the pick; both carry the signers' spots for the packet.
RSpec.describe 'Agreement sheets', type: :request do
  let(:company) { Company.create!(name: "Lakeside Homes #{SecureRandom.hex(3)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56, beds: 3, baths: 2, square_feet: 1493) }
  let(:construction) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'exterior', name: 'Exterior', selection_type: 'multiple') }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    deal.update!(owner_id: user.id)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:co_buyer) { company.contacts.create!(first_name: 'Sam', last_name: 'Smith', email: 'sam@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id, co_applicant_contact_id: co_buyer.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  def option(group, key, name, cost, kind: 'upgrade', standard: false, **attrs)
    CatalogOption.create!(group: group, manufacturer: mfr, key: key, name: name, kind: kind, **attrs)
                 .tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: cost, is_standard: standard) }
  end

  def add(opt, **extra) = post("#{path}/lines", headers: headers, params: { kind: 'option', option_id: opt.id, **extra }.to_json)
  def body = JSON.parse(response.body)
  def pdf_text(data) = PDF::Reader.new(StringIO.new(data)).pages.map(&:text).join("\n")

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    post path, headers: headers, params: { variant_id: variant.id }.to_json

    add option(construction, 'construction--insulation', 'Upgrade Insulation', 1295, factory_code: 'INS38')
    add option(construction, 'construction--beam', 'Wood Beam On Ceiling - Per LF', 60), quantity: 12
    add option(construction, 'construction--package-1', 'Package 1', 2400, kind: 'package', package_items: ['Glamour bath', '9 ft ceilings'])
    clay = option(exterior, 'exterior--siding-clay', 'Clay', 0, kind: 'color', standard: true, metadata: { 'color_set' => 'Siding' })
    option(exterior, 'exterior--siding-flint', 'Flint', 0, kind: 'color', standard: true, metadata: { 'color_set' => 'Siding' })
    stone = option(exterior, 'exterior--shingles-stone', 'Stone Gray', 350, kind: 'color', metadata: { 'color_set' => 'Shingles' })
    option(exterior, 'exterior--shutters-black', 'Black', 0, kind: 'color', standard: true, metadata: { 'color_set' => 'Shutters' })
    option(exterior, 'exterior--door-red', 'Red', 0, kind: 'color', standard: true, metadata: { 'color_set' => 'Front Door' })
    add clay
    add stone
    build = deal.home_build
    build.update!(metadata: build.metadata.merge('color_skips' => ['Shutters']))
  end

  it 'lists every option at retail, adds up to the sheet, and leaves free color picks to the Colors sheet' do
    sheets = Truebuild::AgreementSheets.new(deal.home_build.reload)
    rows = sheets.schedule_rows
    expect(rows.map { |r| r['description'] }).to eq(['Upgrade Insulation', 'Wood Beam On Ceiling - Per LF', 'Package 1', 'Shingles: Stone Gray'])
    expect(rows.first).to include('code' => 'INS38', 'group' => 'Construction', 'status' => 'Upgrade')
    expect(rows[1]).to include('unit' => 'lf', 'quantity' => 12)
    expect(rows[2]['includes']).to eq(['Glamour bath', '9 ft ceilings'])
    expect(rows.flat_map(&:keys).grep(/cost/)).to be_empty

    build = deal.home_build
    extras = build.lines.select { |l| l.priced? && !%w[base option].include?(l.kind) }.sum { |l| l.retail.to_d }
    expect(sheets.base_price + sheets.options_total + extras).to eq(build.totals['gross'].to_d)

    expect(sheets.color_rows.map { |c| [c['group'], c['set'], c['choice'], c['skipped']] }).to eq(
      [['Exterior', 'Front Door', nil, nil], ['Exterior', 'Shingles', 'Stone Gray', nil],
       ['Exterior', 'Shutters', nil, true], ['Exterior', 'Siding', 'Clay', nil]]
    )
    expect(sheets.open_items).to eq(['Colors not chosen: Front Door'])

    build.lines.find_by(label: 'Upgrade Insulation').update!(tbd: true)
    sheets = Truebuild::AgreementSheets.new(build.reload)
    expect(sheets.schedule_rows.first).to include('status' => 'Price to follow', 'price' => nil)
    expect(sheets.open_items).to include('No price yet: Upgrade Insulation')
  end

  it "prints both sheets with the dealer's name, the buyers, and a spot for every signature and initial" do
    headers
    generator = AgreementSheetsPdfGenerator.new(deal.home_build.reload)
    data = generator.generate
    text = pdf_text(data)
    expect(text).to include(company.name, 'Schedule A: Options and Upgrades', 'Color and Finish Selections', 'Pat Smith and Sam Smith',
                            deal.deal_number, '28 x 56, 3 bed, 2 bath, 1,493 sq ft', 'Assigned when the home is built',
                            'Includes: Glamour bath; 9 ft ceilings', 'Code INS38', 'Not chosen yet', 'Not on this home', 'Home with options',
                            'Dealer representative: Rita Rep')
    expect(text).to include('$1,618.75')
    expect(text).not_to include('$1,295.00') # dealer cost never prints

    spots = generator.spots
    %w[schedule_a colors].each do |sheet|
      signed = spots.select { |s| s['sheet'] == sheet && s['kind'] == 'signature' }.map { |s| s['signer'] }
      expect(signed).to eq(%w[buyer_1 buyer_2 rep])
      expect(spots.select { |s| s['sheet'] == sheet && s['kind'] == 'initials' }.map { |s| s['signer'] }.uniq).to contain_exactly('buyer_1', 'buyer_2')
    end
    expect(spots).to all(include('x' => be_between(0, 100), 'y' => be_between(0, 100)))
    expect(spots.map { |s| s['page'] }.max).to eq(PDF::Reader.new(StringIO.new(data)).page_count - 1)

    titled = AgreementSheetsPdfGenerator.new(deal.home_build, sheets: ['schedule_a'], titles: { schedule_a: 'Addendum "A"' }).generate
    expect(pdf_text(titled)).to include('Addendum "A"')
    expect(pdf_text(titled)).not_to include('Color and Finish Selections')
  end

  it 'serves one sheet or both as a PDF, and refuses an unknown sheet' do
    get "#{path}/sheets", headers: headers, params: { sheet: 'colors' }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/pdf')
    expect(pdf_text(response.body)).to include('Color and Finish Selections')
    expect(pdf_text(response.body)).not_to include('Schedule A')

    get "#{path}/sheets", headers: headers
    expect(pdf_text(response.body)).to include('Schedule A', 'Color and Finish Selections')

    get "#{path}/sheets", headers: headers, params: { sheet: 'cover' }
    expect(response).to have_http_status(:bad_request)
  end
end
