# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# explain_record (E118 step 2): why one record came out the way it did, read
# as the person asking, with the same scoping as the app.
RSpec.describe Guide::ExplainRecord do
  include McpConnectorHelpers

  let(:company) { create(:company, industry: 'manufactured_housing', use_rbac_system: false) }
  let(:admin) do
    company.users.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'Ada', last_name: 'Min',
                          password: 'Pass1234!', role: 'admin', status: 'active')
  end
  let(:ctx) { Guide::AppContext.new(user: admin, company: company) }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz') }
  let(:plan) { company.commission_plans.create!(name: 'Sales', is_active: true) }
  let(:deal) do
    company.deals.create!(location: location, contact_id: buyer.id, name: 'Diaz home', selling_price: 100_000, home_cost: 80_000,
                          actual_close_date: Date.current, stage: 'closed_won', owner_id: admin.id,
                          primary_salesperson_id: admin.id, commission_plan_id: plan.id)
  end

  before do
    allow_any_instance_of(ModuleAccessService).to receive(:has_module?).and_return(true)
    company.commission_components.create!(commission_plan: plan, is_active: true, applies_to_role: 'primary_salesperson',
                                          name: 'Agent', component_type: 'percent_of_gross', gross_type: 'house_profit', rate: 0.2)
    deal.deal_products.create!(product_name: 'Delivery and setup', quantity: 1, unit_price: 3_000, cost: 1_000, tax: 0, notes: 'category: service')
  end

  def skipped_facts
    msgs = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |orig, msg|
      msgs << msg if msg.to_s.include?('skipped a fact')
      orig.call(msg)
    end
    yield
    msgs
  end

  it 'explains a deal: lines, gross, books and commission, line by line' do
    out = nil
    skipped = skipped_facts { out = described_class.new(ctx).call('deal', "deal:#{deal.id}") }
    expect(skipped).to be_empty, skipped.join("\n")
    expect(out[:lines].map { |l| l[:name] }).to include('Delivery and setup')
    expect(out[:gross][:front_gross]).to be_present
    expect(out[:books][:approved_to_books]).to be(false)
    expect(out[:commission][:plan]).to eq('Sales')
    expect(out[:commission][:figures].first[:figure]).to be_present
    expect(out[:commission][:figures].first[:lines]).not_to be_empty
  end

  it 'explains an invoice that is not in the books, and why' do
    invoice = company.invoices.create!(location: location, contact: buyer, invoice_date: Date.current, status: 'draft')
    out = described_class.new(ctx).call('invoice', invoice.id)
    expect(out[:in_the_books]).to include(posted: false)
    expect(out[:in_the_books][:why]).to include('draft')
  end

  it 'explains a payment' do
    payment = company.payments.create!(amount: 50, payment_type: 'one_time', status: 'completed', payer: buyer,
                                       payment_date: Date.current, gateway_name: 'manual', location: location)
    out = described_class.new(ctx).call('payment', payment.id)
    expect(out[:amount]).to eq(50.0)
    expect(out[:in_the_books]).to have_key(:posted)
  end

  it 'explains a journal entry and what posted it' do
    cash = company.chart_of_accounts.where(account_type: 'asset', is_header: false).first
    expense = company.chart_of_accounts.where(account_type: 'expense', is_header: false).first
    je = Accounting::ManualPostingService.new(company).post_simple!(debit_account: expense, credit_account: cash, amount: 25,
                                                                    memo: 'Coffee', source_entity: deal, deal_id: deal.id)
    out = described_class.new(ctx).call('journal_entry', je.id)
    expect(out[:lines].size).to eq(2)
    expect(out[:posted_by_what]).to include('approving the deal')
  end

  it 'explains a bank line that is not booked yet' do
    gl = company.chart_of_accounts.where(account_type: 'asset', is_header: false).first
    bank = company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: gl)
    txn = company.bank_transactions.create!(bank_account: bank, description: 'NOCO', amount: -285, transaction_date: Date.current, status: 'unmatched')
    out = described_class.new(ctx).call('bank_transaction', txn.id)
    expect(out[:what_that_means]).to include('Not booked yet')
  end

  it 'says where each agreement field comes from, never what it holds' do
    agreement = company.agreements.create!(
      title: 'Form 500', status: 'draft', deal: deal, contact: buyer,
      merge_field_placements: [
        { 'fieldKey' => 'contact.street', 'fieldLabel' => 'Buyer address', 'page' => 0, 'isCustomField' => false, 'isSignerField' => false },
        { 'fieldKey' => 'signer.signature', 'fieldLabel' => 'Buyer signature', 'page' => 1, 'signerIndex' => 0, 'isSignerField' => true }
      ],
      merge_field_values: { 'contact.street' => '12 SECRET LANE' }
    )
    agreement.agreement_signers.create!(role: 'signer', name: 'Ana Diaz', email: 'ana@example.com', signing_order: 1)
    out = described_class.new(ctx).call('agreement', agreement.id)
    expect(out[:fields].first).to include(label: 'Buyer address', filled_from: "the buyer's contact record")
    expect(out[:fields].last[:filled_by_signer]).to eq('slot 1 (signer)')
    expect(out.to_json).not_to include('SECRET')
  end

  context 'with roles' do
    let(:company) { connector_company }

    before { seed_rbac! }

    it 'refuses someone whose role does not include deals' do
      user = connector_user(company, { 'leads' => %w[read] })
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('deal', deal.id)
      expect(out[:not_allowed]).to be_present
      expect(out.to_json).not_to include('Diaz home')
    end

    it 'cannot open a deal at another location' do
      other = company.locations.create!(name: 'Other lot')
      user = connector_user(company, { 'deals' => %w[read] }, location: other)
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('deal', deal.id)
      expect(out[:not_found]).to be_present
    end

    # Anyone who can read deals sees cost and gross in the app, by design
    # (Tom, 2026-10-01); help shows the same. Commission needs commissions read.
    it 'shows a deal reader what the deal screen shows, but no commission without commissions read' do
      user = connector_user(company, { 'deals' => %w[read] })
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('deal', deal.id)
      expect(out[:gross]).to be_a(Hash)
      expect(out[:commission]).to include('not include commissions')
    end
  end
end
