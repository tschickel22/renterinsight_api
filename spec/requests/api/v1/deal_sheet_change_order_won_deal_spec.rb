# frozen_string_literal: true

require 'rails_helper'

# A change order the buyers sign after the deal is won (or posted to the GL)
# moves the deal's numbers too: lines, selling price and cost. A posted deal
# gets a journal entry for the difference, and its invoice follows.
RSpec.describe 'Deal Sheet change order on a won deal', type: :request do
  let(:packet) { JSON.parse(File.read(Rails.root.join('script/agreement_templates/fdhc_indiana_packet.json'))) }
  let(:company) { Company.create!(name: "Factory Direct #{SecureRandom.hex(3)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let!(:template) { company.agreement_templates.create!(name: 'FD Packet', status: 'active', template_type: 'upload', form_type: 'purchase_agreement', packet: packet) }
  let(:mfr) { Manufacturer.create!(name: 'Champion Home Builders', industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:beam) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--beam', name: 'Wood Beam On Ceiling - Per LF', kind: 'upgrade')
                 .tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 60) }
  end
  let(:rep) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let!(:manager) { User.create!(email: "mgr-#{SecureRandom.hex(4)}@example.com", first_name: 'Max', last_name: 'Manager', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:co_buyer) { company.contacts.create!(first_name: 'Sam', last_name: 'Smith', email: 'sam@example.com') }
  let(:location) { company.locations.create!(name: 'Showroom', state: 'IN') }
  let(:deal) { company.deals.create!(name: 'Smith Bay Port', contact_id: buyer.id, co_applicant_contact_id: co_buyer.id, owner_id: rep.id, location_id: location.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  def body = JSON.parse(response.body)
  def sign_all(agreement) = agreement.agreement_signers.order(:id).each { |s| s.sign!(typed_signature: s.name, signature_method: 'typed') }

  def account(number) = company.chart_of_accounts.find_by(account_number: number)

  before do
    allow(SealAgreementJob).to receive(:perform_now)
    allow(SealAgreementJob).to receive(:perform_later)
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    Truebuild::DealBuild.start(deal: deal, variant: variant)

    post "#{path}/agreement", headers: headers, params: { template_id: template.id, manager_id: manager.id }.to_json
    agreement = company.agreements.find(body['agreement']['id'])
    post "/api/v1/agreements/#{agreement.id}/send_agreement", headers: headers
    sign_all(agreement)
    expect(deal.home_build.reload).to be_locked
  end

  def win!
    deal.reload.update!(stage: company.won_stage_keys.first)
    deal.reload
  end

  # Adds 12 feet of beam on a copy of the signed sheet and has the buyers sign it.
  def sign_change_order!
    live = deal.home_build
    post "#{path}/versions", headers: headers, params: { copy_from_id: live.id, label: 'Add a beam' }.to_json
    draft = deal.home_builds.find_by(label: 'Add a beam')
    post "#{path}/lines?version_id=#{draft.id}", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 12 }.to_json
    post "#{path}/buyer_change_order?version_id=#{draft.id}", headers: headers
    co = company.agreements.find(body['agreement']['id'])
    post "/api/v1/agreements/#{co.id}/send_agreement", headers: headers
    sign_all(co)
    expect(co.reload.status).to eq('completed')
    expect(co.metadata['deal_sheet_not_applied']).to be_nil
    [co, draft.reload]
  end

  it 'moves a won deal\'s price and cost to what the buyers signed' do
    win!
    price = deal.selling_price.to_d
    cost = deal.home_cost.to_d
    expect(price).to be_positive
    expect(cost).to eq(deal.home_line_item.cost.to_d) # the close froze the sheet's cost

    _co, draft = sign_change_order!
    beam_line = draft.lines.find_by(catalog_option_id: beam.id)
    deal.reload
    expect(deal.selling_price.to_d).to eq(price + beam_line.retail.to_d)
    expect(deal.home_cost.to_d).to eq(cost + beam_line.cost.to_d)
    expect(deal.unit_cost.to_d).to eq(deal.home_line_item.cost.to_d)
    expect(deal.total_amount.to_d).to eq(draft.totals['contract_total'].to_d)
  end

  it 'posts the difference to the GL for a posted deal and updates its invoice' do
    win!
    result = Accounting::DealAccountingService.new(deal).post_closing_entries!(user: rep)
    expect(result[:success]).to be(true)
    invoice = DealInvoiceService.new(deal.reload, user: rep).create_invoice!
    closing_revenue = JournalEntryLine.where(journal_entry_id: deal.gl_journal_entry_id).sum(:credit_amount)

    co, draft = sign_change_order!
    beam_line = draft.lines.find_by(catalog_option_id: beam.id)
    deal.reload

    adjustment = company.journal_entries.where(source_entity: deal).where('memo LIKE ?', "Change order #{co.agreement_number}%").sole
    lines = adjustment.journal_entry_lines
    expect(lines.sum(:debit_amount)).to eq(lines.sum(:credit_amount))
    expect(adjustment.entry_date).to eq(Date.current)
    revenue = AccountingSettings.for_company(company).default_sales_revenue_account
    expect(lines.where(chart_of_account_id: revenue.id).sum(:credit_amount)).to eq(beam_line.retail.to_d)
    expect(lines.where(chart_of_account_id: account('1210').id).sum(:credit_amount)).to eq(beam_line.cost.to_d)
    expect(closing_revenue).to be_positive

    expect(invoice.reload.total.to_d).to eq(DealInvoiceService.new(deal).send(:calculate_total))
    expect(invoice.total.to_d).to be > deal.selling_price.to_d - beam_line.retail.to_d
  end

  it 'does not post the home line again as F&I revenue at close' do
    deal.deal_products.create!(product_name: 'Doc fee', product_sku: 'FEE-doc', unit_price: 300, tax: 21, quantity: 1, notes: 'category:fee')
    win!
    Accounting::DealAccountingService.new(deal).post_closing_entries!(user: rep)
    credits = JournalEntryLine.where(journal_entry_id: deal.reload.gl_journal_entry_id).where(chart_of_account_id: AccountingSettings.for_company(company).default_ar_account.id).sum(:debit_amount)
    expect(credits.to_d).to eq(deal.selling_price.to_d + 300)
  end
end
