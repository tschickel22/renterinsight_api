# frozen_string_literal: true

require 'rails_helper'

# The review of 2026-11-03: places a user got stuck, and bugs found alongside them.
RSpec.describe 'Deal Sheet review fixes', type: :request do
  def dealer(name)
    Company.create!(name: "#{name} #{SecureRandom.hex(3)}").tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true)
      c.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
      c.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    end
  end

  let(:company) { dealer('Factory Direct') }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:extras) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:dishwasher) do
    CatalogOption.create!(group: extras, manufacturer: mfr, key: 'dishwasher', name: 'Dishwasher', kind: 'upgrade').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 340)
    end
  end
  let!(:base_price) { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 50_000) }

  def headers_for(co, role = 'company_admin')
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!', company_id: co.id, role: role)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: co.id)}", 'Content-Type' => 'application/json' }
  end
  let(:headers) { headers_for(company) }
  # A rep at the deal's location: can work a deal, is not a company admin.
  let(:showroom) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:rep) do
    user = User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P', password: 'Pass1234!', company_id: company.id, role: 'user')
    Resource.seed_defaults; Action.seed_defaults; Scope.seed_defaults
    role = Role.create!(company_id: company.id, key: "rep-#{SecureRandom.hex(3)}", name: 'Rep', tier: 'location', active: true)
    %w[read update].each do |action|
      RolePermission.create!(role: role, resource: Resource.find_by!(key: 'deals'), action: Action.find_by!(key: action), scope: Scope.find_by!(key: 'all'))
    end
    user.user_role_assignments.create!(role: role, company_id: company.id, tier: 'location', location: showroom)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def new_deal
    contact = company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "pat-#{SecureRandom.hex(3)}@example.com")
    company.deals.create!(name: 'Smith Apex', contact_id: contact.id, location_id: showroom.id)
  end

  def sheet_for
    deal = new_deal
    post path(deal), headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)
    deal
  end

  def path(deal) = "/api/v1/deals/#{deal.id}/home_build"
  def body = JSON.parse(response.body)
  def lines = body.dig('build', 'lines')
  def line_named(name) = lines.find { |l| l['label'] == name }
  def add_line(deal, **attrs, &)
    post "#{path(deal)}/lines", headers: headers, params: attrs.to_json
    expect(response).to have_http_status(:created)
  end

  describe 'an add-on from the list going on Addendum A' do
    let!(:addon) do
      package = company.package_templates.create!(name: 'Power pole', default_price: 900, cost: 500)
      company.truebuild_addons.create!(source: package, mode: 'quote_only')
    end

    it 'moves up, leaves the list so it cannot be charged twice, and untick puts it back' do
      deal = sheet_for
      add_line(deal, kind: 'addon', addon_id: addon.id)
      line = lines.find { |l| l['addon_id'] == addon.id }

      patch "#{path(deal)}/lines/#{line['id']}", headers: headers, params: { on_addendum: true }.to_json
      expect(response).to have_http_status(:ok)
      moved = line_named('Power pole')
      expect(moved).to include('kind' => 'option', 'tax_category' => 'factory_option', 'dealer_upgrade' => true, 'addon_id' => nil)

      get "#{path(deal)}/options", headers: headers
      expect(body['addons'].map { |a| a['name'] }).not_to include('Power pole')
      expect(body['groups'].flat_map { |g| g['options'] }.map { |o| o['name'] }).to include('Power pole')

      patch "#{path(deal)}/lines/#{moved['id']}", headers: headers, params: { on_addendum: false }.to_json
      expect(line_named('Power pole')).to include('kind' => 'addon', 'addon_id' => addon.id, 'dealer_upgrade' => false)
      get "#{path(deal)}/options", headers: headers
      expect(body['addons'].map { |a| a['name'] }).to include('Power pole')
    end

    it 'takes a set-up item too, but never the document fee' do
      deal = sheet_for
      add_line(deal, kind: 'custom', label: 'Skirting', unit_retail: 1000, tax_category: 'setup')
      patch "#{path(deal)}/lines/#{line_named('Skirting')['id']}", headers: headers, params: { on_addendum: true }.to_json
      expect(line_named('Skirting')).to include('kind' => 'option')

      add_line(deal, kind: 'custom', label: 'Doc fee', unit_retail: 251, tax_category: 'fee')
      patch "#{path(deal)}/lines/#{line_named('Doc fee')['id']}", headers: headers, params: { on_addendum: true }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'the document fee override' do
    before { company.dealer_catalog_terms.first.update!(doc_fee: 395) }

    it 'is a company admin\'s, and a rep is refused' do
      deal = sheet_for
      fee = line_named('Doc fee')
      expect(fee['fee_locked']).to be(false)
      patch "#{path(deal)}/lines/#{fee['id']}", headers: rep, params: { unit_retail: 1 }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to eq(Truebuild::DealBuild::DOC_FEE_LOCKED)
      get path(deal), headers: rep
      expect(line_named('Doc fee')['fee_locked']).to be(true)

      patch "#{path(deal)}/lines/#{fee['id']}", headers: headers, params: { unit_retail: 200 }.to_json
      expect(response).to have_http_status(:ok)
      expect(line_named('Doc fee')['retail']).to eq(200.0)
      expect(deal.home_build.lines.find(fee['id']).metadata['fee_override']).to include('was' => 395.0)

      delete "#{path(deal)}/lines/#{fee['id']}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(line_named('Doc fee')).to be_nil
    end
  end

  describe 'a home no price book has' do
    let(:typed) { { description: '2018 Clayton Ultra', maker: 'Clayton', model: 'U-28', width_ft: 28, length_ft: 60, beds: 3, baths: 2, price: 72_000, cost: 55_000 } }

    it 'starts a sheet with the typed price and cost, adds lines, and reaches the deal and contract' do
      deal = new_deal
      post path(deal), headers: headers, params: { manual_home: typed }.to_json
      expect(response).to have_http_status(:created)
      expect(body.dig('build', 'manual_home')).to be(true)
      expect(body.dig('build', 'model', 'model_number')).to eq('U-28')
      expect(line_named('2018 Clayton Ultra')).to include('retail' => 72_000.0, 'cost' => 55_000.0)
      expect(lines.map { |l| l['kind'] }).not_to include('freight')
      expect(lines.any? { |l| l['not_offered'] }).to be(false)
      expect(body.dig('build', 'totals', 'gross')).to eq(72_000.0)

      add_line(deal, kind: 'custom', label: 'Steps', unit_retail: 800, on_addendum: true)
      expect(line_named('Steps')).to include('kind' => 'option', 'retail' => 800.0)
      get "#{path(deal)}/options", headers: headers
      expect(response).to have_http_status(:ok)
      expect(body['groups'].first['options'].first).to include('name' => 'Steps', 'price' => 800.0, 'chosen' => true)

      deal.reload
      expect(deal.home_line_item.product_name).to eq('2018 Clayton Ultra')
      values = Agreements::PacketValues.new(deal).to_h
      expect(values).to include('home.manufacturer' => 'Clayton', 'home.model_number' => 'U-28')
      get "#{path(deal)}/agreement", headers: headers
      expect(response).to have_http_status(:ok)

      post "#{path(deal)}/purchase_order", headers: headers, params: {}.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'never shows in the model list' do
      deal = new_deal
      post path(deal), headers: headers, params: { manual_home: typed }.to_json
      get "#{path(deal)}/models", headers: headers
      expect(body['plans'].map { |p| p['name'] }).not_to include('2018 Clayton Ultra')
    end

    it 'can replace a catalog home on the sheet' do
      deal = sheet_for
      patch path(deal), headers: headers, params: { manual_home: typed }.to_json
      expect(response).to have_http_status(:ok)
      expect(body.dig('build', 'manual_home')).to be(true)
      expect(line_named('2018 Clayton Ultra')['retail']).to eq(72_000.0)
    end

    it 'needs a description' do
      post path(new_deal), headers: headers, params: { manual_home: { maker: 'Clayton' } }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'a won deal with an unsigned sheet' do
    def won_deal
      deal = sheet_for
      add_line(deal, kind: 'custom', label: 'Steps', unit_retail: 800, unit_cost: 300)
      deal.reload.update!(stage: company.won_stage_keys.first)
      deal.reload
    end

    it 'a rep corrects it and the deal follows' do
      deal = won_deal
      expect(deal).to be_cost_snapshotted
      line = deal.home_build.lines.find_by!(label: 'Steps')

      patch "#{path(deal)}/lines/#{line.id}", headers: rep, params: { unit_retail: 900 }.to_json
      expect(response).to have_http_status(:ok)
      expect(body.dig('build', 'closed')).to be(true)
      expect(deal.reload.deal_products.find_by(product_name: 'Steps').unit_price).to eq(900)
    end

    it 'commission follows the correction: open payments change, paid ones stand' do
      deal = won_deal
      seller = User.create!(email: "s-#{SecureRandom.hex(4)}@example.com", first_name: 'S', last_name: 'R', password: 'Pass1234!', company_id: company.id, role: 'user')
      plan = company.commission_plans.create!(name: 'Std', is_default: true)
      company.commission_components.create!(commission_plan: plan, name: 'Add-ons', component_type: 'addon_commission', rate: 0.10, is_active: true, applies_to_role: 'primary_salesperson')
      deal.update!(commission_plan_id: plan.id, owner_id: seller.id)
      pending = company.commission_payments.create!(deal_id: deal.id, payee_user_id: seller.id, commission_plan_id: plan.id, amount: 80, status: 'pending')
      line = deal.home_build.lines.find_by!(label: 'Steps')

      patch "#{path(deal)}/lines/#{line.id}", headers: rep, params: { unit_retail: 900 }.to_json
      expect(response).to have_http_status(:ok)
      expect(pending.reload.amount).to eq(90)

      pending.update_columns(status: 'paid')
      patch "#{path(deal)}/lines/#{line.id}", headers: rep, params: { unit_retail: 1000 }.to_json
      expect(pending.reload.amount).to eq(90)
      adjustment = company.commission_payments.where(deal_id: deal.id).where.not(id: pending.id).first
      expect(adjustment).to have_attributes(amount: 10, status: 'pending')

      patch "#{path(deal)}/lines/#{line.id}", headers: rep, params: { unit_retail: 700 }.to_json
      expect(adjustment.reload.status).to eq('cancelled')
      expect(pending.reload.calculation_details['overpaid_after_change']).to eq(20.0)
    end

    it 'a correction keeps the other prices it was sold at, and opening does not move them' do
      deal = won_deal
      base = deal.home_build.lines.find_by!(kind: 'base')
      sold = base.unit_retail
      company.dealer_markup_rules.first.update!(value: 40, updated_at: 1.minute.from_now)
      get path(deal), headers: headers
      expect(deal.home_build.reload.lines.find(base.id).unit_retail).to eq(sold)

      post "#{path(deal)}/reprice", headers: headers
      expect(response).to have_http_status(:ok)
      expect(deal.home_build.reload.lines.find(base.id).unit_retail).to eq(sold)
    end

    it 'cannot be cleared' do
      deal = won_deal
      delete path(deal), headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(deal.reload.home_build).to be_present
    end
  end

  describe 'a signed sheet' do
    def signed_deal
      deal = sheet_for
      deal.home_build.update!(status: 'locked')
      deal.reload
    end

    it 'takes a late cost from a rep with no new signature, and moves only the cost' do
      deal = signed_deal
      freight_or_base = deal.home_build.lines.find_by!(kind: 'base')
      before = deal.home_build.totals['contract_total']
      post "#{path(deal)}/lines/#{freight_or_base.id}/correct_cost", headers: rep, params: { unit_cost: 40_000 }.to_json
      expect(response).to have_http_status(:ok)
      expect(body.dig('build', 'totals', 'contract_total')).to eq(before)
      freight = deal.home_build.reload.lines.find_by(kind: 'freight')&.cost.to_d
      expect(deal.reload.home_line_item.cost).to eq(40_000 + freight)
      expect(deal.home_build).to be_locked
    end

    it 'keeps lender and approval dates open, but not what sets the price' do
      deal = signed_deal
      patch "/api/v1/deals/#{deal.id}/sale_details", headers: headers, params: { loan_officer: 'Sam', approval_date: '2026-12-01' }.to_json
      expect(response).to have_http_status(:ok)
      patch "/api/v1/deals/#{deal.id}/sale_details", headers: headers, params: { delivery_state: 'OH' }.to_json
      expect(response).to have_http_status(:conflict)
    end

    it 'a draft cannot change the deal\'s terms under it, nor can the deal form' do
      deal = signed_deal
      post "#{path(deal)}/versions", headers: headers, params: { copy_from_id: deal.home_build.id }.to_json
      draft = body.dig('build', 'id')
      patch "#{path(deal)}?version_id=#{draft}", headers: headers, params: { deal: { trade_allowance: 5000 } }.to_json
      expect(response).to have_http_status(:conflict)
      expect(deal.reload.trade_allowance.to_d).to eq(0)

      patch "/api/crm/deals/#{deal.id}", headers: headers, params: { deal: { trade_allowance: 5000 } }.to_json
      expect(response).to have_http_status(:conflict)
      patch "/api/crm/deals/#{deal.id}", headers: headers, params: { deal: { name: 'Renamed', trade_allowance: 0 } }.to_json
      expect(response).to have_http_status(:ok)
    end

    it 'a change order accepts a difference in only the discount' do
      deal = signed_deal
      live = deal.home_build
      draft = Truebuild::DealBuild.new(live).copy.build
      service = Truebuild::DealBuild.new(draft)
      service.set_discounts(other_amount: 500)
      co = Agreements::BuyerChangeOrder.new(deal.reload, draft.reload, user: nil)
      expect(co.changes[:lines]).to be_empty
      expect(co.check).not_to include('Nothing differs from the signed version yet')
    end

    it 'a change order shows both of two lines with the same name' do
      deal = sheet_for
      add_line(deal, kind: 'custom', label: 'Steps', unit_retail: 100)
      deal.reload.home_build.update!(status: 'locked')
      draft = Truebuild::DealBuild.new(deal.home_build).copy.build
      Truebuild::DealBuild.new(draft).add_custom(label: 'Steps', unit_retail: 200)
      co = Agreements::BuyerChangeOrder.new(deal.reload, draft.reload, user: nil)
      expect(co.changes[:lines].select { |l| l['description'] == 'Steps' }.map { |l| l['change'] }).to eq(['add'])
    end
  end

  describe 'other fixes' do
    it 'a buyer with no email can still make the agreement, and is told how to sign' do
      deal = sheet_for
      deal.contact.update_column(:email, '')
      check = Agreements::FromDealSheet.new(deal.reload, user: nil).check
      expect(check[:blocking].join).not_to include('email')
      expect(check[:open].join).to include('sign on paper')
    end

    it 'a line with no price blocks the agreement, and the home is never negative' do
      deal = sheet_for
      add_line(deal, kind: 'custom', label: 'Doc fee', unit_retail: 500, tax_category: 'fee')
      base = deal.home_build.lines.find_by!(kind: 'base')
      patch "#{path(deal)}/lines/#{base.id}", headers: headers, params: { unit_retail: nil }.to_json
      Truebuild::DealBuild.new(deal.reload.home_build).tap do |s|
        s.build.lines.find(base.id).update!(unit_retail: nil, retail: nil, metadata: { 'set_retail' => true })
        allow(s).to receive(:engine).and_return(nil)
        s.reprice!
      end
      expect(deal.reload.home_line_item.unit_price).to be >= 0
      expect(Agreements::FromDealSheet.new(deal, user: nil).check[:blocking].join).to include('No price yet')
    end

    it 'the contract puts only the document fee in its box' do
      deal = sheet_for
      add_line(deal, kind: 'custom', label: 'Document preparation fee', unit_retail: 251, tax_category: 'fee')
      add_line(deal, kind: 'custom', label: 'Title work', unit_retail: 75, tax_category: 'fee')
      values = Agreements::PacketValues.new(deal.reload).to_h
      expect(values['price.doc_fee']).to eq('$251.00')
      expect(values['price.other']).to eq('$75.00')
      expect(values['price.other_label']).to eq('Title work')
    end

    it 'buyer pickup takes freight off, and delivery brings it back' do
      deal = sheet_for
      expect(lines.map { |l| l['kind'] }).to include('freight')
      patch path(deal), headers: headers, params: { deal: { delivery_point: 'lot' } }.to_json
      expect(lines.map { |l| l['kind'] }).not_to include('freight')
      patch path(deal), headers: headers, params: { deal: { delivery_point: 'deliver' } }.to_json
      expect(lines.map { |l| l['kind'] }).to include('freight')
    end

    it 'freight can be removed' do
      deal = sheet_for
      id = lines.find { |l| l['kind'] == 'freight' }['id']
      delete "#{path(deal)}/lines/#{id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(lines.map { |l| l['kind'] }).not_to include('freight')
    end

    it 'changing the home keeps what the rep added' do
      deal = sheet_for
      add_line(deal, kind: 'option', option_id: dishwasher.id)
      add_line(deal, kind: 'custom', label: 'Steps', unit_retail: 100)
      other = CatalogPlanVariant.create!(catalog_plan: CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Summit'),
                                         manufacturer: mfr, model_number: '1676H32P02', width_ft: 16, length_ft: 76)
      CatalogVariantPrice.create!(price_book: book, variant: other, net_base_price: 40_000)
      patch path(deal), headers: headers, params: { variant_id: other.id }.to_json
      expect(response).to have_http_status(:ok)
      expect(line_named('Steps')['retail']).to eq(100.0)
      expect(line_named('Dishwasher')).to be_nil
      expect(lines.count { |l| l['kind'] == 'base' }).to eq(1)
    end

    it 'a trade saved on the deal reprices the sheet when next opened' do
      deal = sheet_for
      before = body.dig('build', 'totals', 'contract_total')
      deal.reload.update!(trade_allowance: 1000)
      get path(deal), headers: headers
      expect(body.dig('build', 'totals', 'contract_total')).to eq(before - 1000)
    end

    it 'a model from a factory the dealer was not given is refused' do
      other_factory = mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}")
      other_factory.update!(truebuild_released_at: Time.current)
      company.dealer_factories.create!(factory: other_factory)
      post path(new_deal), headers: headers, params: { variant_id: variant.id }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'a signature that fails to apply says so on the sheet' do
      deal = sheet_for
      agreement = company.agreements.create!(title: 'CO', deal: deal, contact: deal.contact, content_type: 'pdf_upload', status: 'completed',
                                             metadata: { 'deal_sheet_not_applied' => { 'reason' => 'Signed, but the Deal Sheet was not changed: closed period.' } })
      get path(deal), headers: headers
      expect(body.dig('build', 'warnings').join).to include(agreement.agreement_number, 'closed period')
    end

    it 'a person with no locations at all under location permissions sees no deals' do
      deal = sheet_for
      lonely = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", first_name: 'X', last_name: 'Y', password: 'Pass1234!', company_id: company.id, role: 'user')
      company.update!(use_rbac_system: true)
      get path(deal), headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: lonely.id, company_id: company.id)}" }
      expect(response).to have_http_status(:not_found).or have_http_status(:forbidden)
    end

    it 'home details can be corrected on the sheet and reach the contract' do
      deal = sheet_for
      patch path(deal), headers: headers, params: { home_specs: { beds: 4, baths: 2.5, width_ft: 30, length_ft: 60, square_feet: 1800 } }.to_json
      expect(response).to have_http_status(:ok)
      expect(body.dig('build', 'model')).to include('beds' => 4, 'baths' => 2.5, 'width_ft' => 30, 'square_feet' => 1800)
      values = Agreements::PacketValues.new(deal.reload).to_h
      expect(values).to include('home.beds' => '4', 'home.baths' => '2.5', 'home.floor_size' => '30 x 60', 'home.square_feet' => '1800')
      expect(values['home.size']).to include('4 bed', '2.5 bath')
      expect(variant.reload.beds).not_to eq(4)
    end

    it 'previews the factory order and the agreement without creating anything' do
      deal = sheet_for
      get "#{path(deal)}/purchase_order/preview", headers: headers
      expect(response).to have_http_status(:ok)
      expect(body['lines'].first).to include('kind' => 'base')
      expect(deal.reload.purchase_orders).to be_empty

      packet = JSON.parse(File.read(Rails.root.join('script/agreement_templates/fdhc_indiana_packet.json')))
      template = company.agreement_templates.create!(name: 'FD Packet', status: 'active', template_type: 'upload', form_type: 'purchase_agreement', packet: packet)
      get "#{path(deal)}/agreement/preview", headers: headers, params: { template_id: template.id }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/pdf')
      expect(company.agreements.where(deal_id: deal.id)).to be_empty
    end

    it 'a home on the lot takes a PO only when the rep overrides' do
      deal = sheet_for
      deal.home_build.update!(source: 'lot')
      post "#{path(deal)}/purchase_order", headers: headers, params: { supplier_name: 'Champion' }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      post "#{path(deal)}/purchase_order", headers: headers, params: { supplier_name: 'Champion', override: true }.to_json
      expect(response).to have_http_status(:created)
      expect(deal.reload.purchase_orders.count).to eq(1)
    end

    it 'staff with a company-wide role reach any location, as admins do' do
      deal = sheet_for
      user = User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'W', password: 'Pass1234!', company_id: company.id, role: 'user')
      Resource.seed_defaults; Action.seed_defaults; Scope.seed_defaults
      role = Role.create!(company_id: company.id, key: "all-#{SecureRandom.hex(3)}", name: 'All', tier: 'company', active: true)
      RolePermission.create!(role: role, resource: Resource.find_by!(key: 'deals'), action: Action.find_by!(key: 'read'), scope: Scope.find_by!(key: 'all'))
      user.user_role_assignments.create!(role: role, company_id: company.id, tier: 'company')
      company.update!(use_rbac_system: true)
      get path(deal), headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
      expect(response).to have_http_status(:ok)
    end

    it 'an add-on or package price can apply going forward, and this deal takes it' do
      package = company.package_templates.create!(name: 'Power pole', default_price: 900, cost: 500)
      addon = company.truebuild_addons.create!(source: package, mode: 'quote_only')
      deal = sheet_for
      add_line(deal, kind: 'addon', addon_id: addon.id)
      line = lines.find { |l| l['addon_id'] == addon.id }
      post "#{path(deal)}/remember", headers: rep, params: { line_id: line['id'], price: 1000, cost: 600 }.to_json
      expect(response).to have_http_status(:ok)
      expect(addon.reload.price).to eq(1000)
      expect(package.reload.cost).to eq(600)
      expect(line_named('Power pole')).to include('retail' => 1000.0, 'unit_cost' => 600.0)

      fee = company.fee_templates.create!(name: 'Title work', fee_type: 'other', default_amount: 75)
      add_line(deal, kind: 'template', template_type: 'FeeTemplate', template_id: fee.id)
      post "#{path(deal)}/remember", headers: rep, params: { line_id: line_named('Title work')['id'], price: 90 }.to_json
      expect(fee.reload.default_amount).to eq(90)
      expect(line_named('Title work')['retail']).to eq(90.0)
    end

    it 'a picked option set TBD comes back decided when picked again' do
      deal = sheet_for
      add_line(deal, kind: 'option', option_id: dishwasher.id)
      id = line_named('Dishwasher')['id']
      patch "#{path(deal)}/lines/#{id}", headers: headers, params: { tbd: true }.to_json
      add_line(deal, kind: 'option', option_id: dishwasher.id)
      expect(line_named('Dishwasher')['tbd']).to be(false)
    end
  end
end
