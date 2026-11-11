# frozen_string_literal: true

require 'rails_helper'

# E99: bank feed lines go to projects, deals and draws. Spending categorized
# to a project is a paid cost line on it (it counts against the budget); a
# lender's draw deposit is applied to the deal it was for and fills the draw.
RSpec.describe 'Bank feed to projects and deals', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:account) { company.accounts.create!(name: 'Diaz') }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:ar) do
    company.chart_of_accounts.create!(account_number: '1190', name: 'Accounts Receivable', account_type: 'asset',
                                      sub_type: 'accounts_receivable', normal_balance: 'debit')
  end
  let(:revenue) do
    company.chart_of_accounts.create!(account_number: '4090', name: 'Sales Revenue', account_type: 'revenue', normal_balance: 'credit')
  end
  let(:install_cost) do
    company.chart_of_accounts.create!(account_number: '5990', name: 'Install Cost', account_type: 'expense', normal_balance: 'debit')
  end
  let(:bank_gl) do
    company.chart_of_accounts.create!(account_number: '1099', name: 'Operating Checking', account_type: 'asset',
                                      sub_type: 'bank', normal_balance: 'debit')
  end
  let(:bank) { company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: bank_gl) }

  before do
    AccountingSettings.for_company(company).update!(default_ar_account: ar, default_sales_revenue_account: revenue, auto_post_deals: false)
  end

  def body = JSON.parse(response.body)

  def approved_deal(price: 100_000)
    deal = company.deals.create!(location: location, name: 'Diaz home', account: account, selling_price: price, actual_close_date: Date.current - 10)
    deal.update!(stage: 'closed_won')
    result = Accounting::DealAccountingService.new(deal).post_closing_entries!(user: dealer)
    expect(result).to include(success: true), result.inspect
    deal.reload
  end

  def with_draws(deal)
    invoice = DealInvoiceService.new(deal, user: dealer).create_invoice!
    invoice.update_columns(draw_schedule: { 'draws' => [
      { 'position' => 1, 'description' => 'Down payment', 'amount' => 10_000, 'due_date' => Date.current.to_s, 'status' => 'pending', 'paid_amount' => 0 },
      { 'position' => 2, 'description' => 'Lender funding', 'kind' => 'lender', 'amount' => 90_000, 'due_date' => (Date.current + 30).to_s, 'status' => 'pending', 'paid_amount' => 0 }
    ] })
    invoice
  end

  def txn!(amount, description)
    company.bank_transactions.create!(bank_account: bank, description: description, amount: amount,
                                      transaction_date: Date.current, status: 'unmatched')
  end

  def path(txn, action) = "/api/v1/bank_accounts/#{bank.id}/transactions/#{txn.id}/#{action}"

  describe 'categorizing to a project' do
    let(:deal) { approved_deal }
    let(:project) { company.projects.create!(name: 'Diaz home', status: 'active', deal: deal, budget_amount: 20_000) }
    let!(:set_phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, estimated_budget: 8000) }
    let(:crew) { company.vendors.create!(name: 'Ace Set Crew', vendor_type: 'contractor') }

    it 'makes a paid cost line with the vendor and phase, and unmatch takes it away' do
      t = txn!(-2450, 'ACE SET CREW')
      post path(t, 'categorize'), headers: headers, params: {
        account_id: install_cost.id, project_id: project.id, project_phase_id: set_phase.id, vendor_id: crew.id, create_je: true
      }.to_json
      expect(response).to have_http_status(:ok), response.body
      expect(body).to include('project' => include('id' => project.id), 'vendor' => include('name' => 'Ace Set Crew'))

      line = t.reload.matched_journal_entry.journal_entry_lines.find_by(chart_of_account: install_cost)
      expect(line).to have_attributes(project_id: project.id, deal_id: deal.id, debit_amount: 2450)
      cost = ProjectCostItem.not_deleted.find_by(project_id: project.id)
      expect(cost).to have_attributes(amount: 2450, status: 'paid', vendor_id: crew.id, project_phase_id: set_phase.id)

      post path(t, 'unmatch'), headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(ProjectCostItem.not_deleted.where(project_id: project.id)).to be_empty
      expect(t.reload).to have_attributes(status: 'unmatched', project_id: nil, vendor_id: nil)
    end

    it 'tags income to the project and its deal' do
      t = txn!(500, 'REBATE')
      post path(t, 'categorize'), headers: headers, params: { account_id: revenue.id, project_id: project.id, create_je: true }.to_json
      expect(response).to have_http_status(:ok), response.body
      line = t.reload.matched_journal_entry.journal_entry_lines.find_by(chart_of_account: revenue)
      expect(line).to have_attributes(project_id: project.id, deal_id: deal.id, credit_amount: 500)
      expect(ProjectCostItem.not_deleted.where(project_id: project.id)).to be_empty
    end

    it 'refuses a phase from another project' do
      other = company.projects.create!(name: 'Lopez', status: 'active')
      stray = other.project_phases.create!(company: company, name: 'Other', position: 0)
      t = txn!(-100, 'X')
      post path(t, 'categorize'), headers: headers, params: { account_id: install_cost.id, project_id: project.id, project_phase_id: stray.id, create_je: true }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(t.reload.status).to eq('unmatched')
    end

    it 'lets a rule file a line to the project' do
      rule = company.bank_rules.create!(name: 'Ace', bank_account: bank, match_type: 'contains', match_field: 'description',
                                        match_value: 'ACE', transaction_direction: 'withdrawal', assign_account_id: install_cost.id,
                                        assign_project_id: project.id, auto_confirm: true, is_active: true, priority: 1)
      t = txn!(-300, 'ACE SET CREW 2')
      BankTransactionMatchingService.new(company).auto_match(t)
      expect(t.reload).to have_attributes(status: 'matched', project_id: project.id)
      expect(ProjectCostItem.not_deleted.find_by(project_id: project.id).amount).to eq(300)
    end
  end

  describe 'a deposit applied to a deal' do
    let(:deal) { approved_deal }
    let!(:invoice) { with_draws(deal) }
    let!(:project) { company.projects.create!(name: 'Diaz home', status: 'active', deal: deal) }

    it 'suggests the deal whose draw matches, fills the draw and links the deal and project' do
      t = txn!(10_000, 'WIRE DIAZ')
      get path(t, 'payment_options'), headers: headers
      expect(response).to have_http_status(:ok), response.body
      option = body['deals'].first
      expect(option).to include('id' => deal.id, 'exact' => true)
      expect(option['next_draw']).to include('description' => 'Down payment', 'balance' => 10_000.0)
      expect(option['project']).to include('id' => project.id)

      post path(t, 'apply_payment'), headers: headers, params: { deal_id: deal.id }.to_json
      expect(response).to have_http_status(:ok), response.body
      expect(body).to include('deal' => include('id' => deal.id), 'project' => include('id' => project.id))
      expect(invoice.reload.amount_due).to eq(90_000)
      receipt = CashReceipt.find(t.reload.cash_receipt_id)
      expect(t.matched_journal_entry_id).to eq(receipt.journal_entry_id)
      expect(receipt).to have_attributes(bank_account_id: bank.id, receipt_date: Date.current, deal_id: deal.id)
      expect(Reports::DrawProgress.call(invoice).first[:status]).to eq('paid')

      # The lender's draw lines up with the deal next.
      lender = txn!(90_000, 'LENDER FUNDING')
      get path(lender, 'payment_options'), headers: headers
      expect(body['deals'].first).to include('id' => deal.id, 'exact' => true)

      post path(t, 'unmatch'), headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(receipt.reload.status).to eq(CashReceipt::STATUS_VOIDED)
      expect(invoice.reload.amount_due).to eq(100_000)
      expect(t.reload).to have_attributes(status: 'unmatched', cash_receipt_id: nil, deal_id: nil)
    end

    it 'refuses a withdrawal and a line already matched' do
      out = txn!(-10_000, 'OUT')
      post path(out, 'apply_payment'), headers: headers, params: { deal_id: deal.id }.to_json
      expect(response).to have_http_status(:unprocessable_entity)

      t = txn!(10_000, 'IN')
      post path(t, 'apply_payment'), headers: headers, params: { deal_id: deal.id }.to_json
      post path(t, 'apply_payment'), headers: headers, params: { deal_id: deal.id }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invoice.reload.amount_due).to eq(90_000)
    end
  end

  it 'applies a deposit to an open project invoice (an installer billing the dealer)' do
    project = company.projects.create!(name: 'Install for EHS', status: 'active')
    invoice = company.invoices.create!(invoice_number: "INV-#{SecureRandom.hex(3)}", status: 'sent', total: 12_000, subtotal: 12_000,
                                       amount_due: 12_000, source_type: 'Project', source_id: project.id, location: location,
                                       recipient: account, due_date: Date.current + 15, invoice_date: Date.current)
    invoice.invoice_items.create!(description: 'Install', quantity: 1, rate: 12_000)
    invoice.save!
    t = txn!(12_000, 'EHS ACH')
    get path(t, 'payment_options'), headers: headers
    expect(body['invoices'].first).to include('id' => invoice.id, 'exact' => true, 'project' => include('id' => project.id))

    post path(t, 'apply_payment'), headers: headers, params: { invoice_id: invoice.id }.to_json
    expect(response).to have_http_status(:ok), response.body
    expect(invoice.reload).to have_attributes(amount_due: 0, status: 'paid')
    expect(t.reload).to have_attributes(invoice_id: invoice.id, project_id: project.id, status: 'matched')
  end
end
