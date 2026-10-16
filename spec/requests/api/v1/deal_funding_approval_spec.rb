# frozen_string_literal: true

require 'rails_helper'

# E78 steps 2 and 3: deposits taken before approval, and the approval screen
# recording the payment plan and money received at closing.
RSpec.describe 'Deal funding at approval', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') } # seeds the chart of accounts
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
  let(:deposits) { company.chart_of_accounts.find_by!(account_number: '2410') }
  let(:bank_gl) { company.chart_of_accounts.where(account_type: 'asset', is_header: false).order(:account_number).first }
  let(:bank) { company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: bank_gl) }
  let(:deal) do
    company.deals.create!(location: location, name: 'Diaz home', account: account, selling_price: 100_000,
                          actual_close_date: Date.current, stage: 'closed_won', payment_type: 'financed',
                          lender_name: 'Triad', financed_amount: 80_000)
  end

  before do
    AccountingSettings.for_company(company).update!(default_ar_account: ar, default_sales_revenue_account: revenue, auto_post_deals: false)
  end

  def body = JSON.parse(response.body)

  def take_deposit(amount)
    post "/api/v1/deals/#{deal.id}/record_payment", headers: headers,
                                                   params: { amount: amount, bank_account_id: bank.id, payment_method: 'check' }.to_json
    expect(response).to have_http_status(:ok), response.body
    company.cash_receipts.find(body.dig('cash_receipt', 'id'))
  end

  def approve(funding)
    post "/api/v1/deal_approvals/#{deal.id}/approve", headers: headers, params: { funding: funding }.to_json
  end

  def balance(account_id, deal_id: nil)
    lines = JournalEntryLine.joins(:journal_entry).merge(JournalEntry.in_ledger)
                            .where(journal_entries: { company_id: company.id }, chart_of_account_id: account_id)
    lines = lines.where(deal_id: deal_id) if deal_id
    lines.sum('debit_amount - credit_amount').to_d
  end

  it 'holds a deposit before approval and applies it to the invoice at approval' do
    receipt = take_deposit(5000)
    expect(body['deposit']).to be(true)
    expect(receipt).to have_attributes(deal_id: deal.id, amount_unapplied: 5000)
    expect(balance(deposits.id, deal_id: deal.id)).to eq(-5000)
    expect(balance(ar.id)).to eq(0)

    get "/api/v1/deal_approvals/#{deal.id}", headers: headers
    expect(body['funding']).to include('deposits_total' => 5000.0,
                                       'default_plan' => include('type' => 'financed', 'lender_amount' => 80_000.0))

    approve(plan: { type: 'financed', lender_amount: 80_000, lender_due_date: (Date.current + 20).to_s },
            receipts: [{ amount: 15_000, payment_date: Date.current.to_s, payment_method: 'wire', bank_account_id: bank.id }])
    expect(response).to have_http_status(:ok), response.body
    expect(body['funding']).to include('total' => 100_000.0, 'received' => 20_000.0, 'owed' => 80_000.0, 'errors' => [])

    invoice = company.invoices.find(deal.reload.deal_invoice_id)
    draws = invoice.draw_schedule['draws']
    expect(draws.map { |d| [d['description'], d['amount'], d['status']] })
      .to eq([['Down payment', 20_000.0, 'paid'], ['Lender funding, Triad', 80_000.0, 'pending']])
    expect(receipt.reload.amount_unapplied).to eq(0)
    expect(balance(deposits.id, deal_id: deal.id)).to eq(0)
    expect(balance(ar.id)).to eq(80_000) # 100,000 booked, 5,000 deposit and 15,000 at closing applied

    get '/api/v1/accounting/reports/deal_funding', headers: headers
    row = body['deals'].find { |r| r['id'] == deal.id }
    expect(row).to include('received' => 20_000.0, 'owed' => 80_000.0, 'books_check' => 'ok', 'status' => 'open')
    expect(row['next_draw']).to include('description' => 'Lender funding, Triad')
  end

  it 'keeps an overpayment at closing on the deal as a deposit' do
    approve(plan: { type: 'single', due_date: Date.current.to_s },
            receipts: [{ amount: 100_500, payment_date: Date.current.to_s, bank_account_id: bank.id }])
    expect(response).to have_http_status(:ok), response.body
    expect(body['funding']).to include('owed' => 0.0)
    expect(company.cash_receipts.where(deal_id: deal.id).sum(:amount_unapplied)).to eq(500)
    expect(company.invoices.find(deal.reload.deal_invoice_id).draw_schedule).to be_blank
  end

  it 'stops the approval before posting when a payment row is wrong' do
    approve(plan: { type: 'single' }, receipts: [{ amount: 1000, bank_account_id: 0 }])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to match(/bank account/)
    expect(deal.reload.gl_posted_at).to be_nil

    approve(plan: { type: 'draws', template_id: 0 })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(deal.reload.gl_posted_at).to be_nil
  end

  it 'undoes an applied deposit when the receipt is voided' do
    receipt = take_deposit(5000)
    approve(plan: { type: 'single' })
    invoice = company.invoices.find(deal.reload.deal_invoice_id)
    expect(invoice.amount_due).to eq(95_000)

    receipt.reload.void!
    expect(invoice.reload.amount_due).to eq(100_000)
    expect(balance(ar.id)).to eq(100_000)
    expect(balance(deposits.id, deal_id: deal.id)).to eq(0)
  end

  it 'invoices an approved deal that has none when a payment is recorded' do
    expect(Accounting::DealAccountingService.new(deal).post_closing_entries!(user: dealer)).to include(success: true)
    take_deposit(1000)
    expect(body['deposit']).to be(false)
    expect(company.invoices.find(deal.reload.deal_invoice_id).amount_paid).to eq(1000)
  end

  it 'refuses a deposits account that is not a liability that takes postings' do
    settings = AccountingSettings.for_company(company)
    expect(settings.update(customer_deposits_account_id: ar.id)).to be(false)
    header = company.chart_of_accounts.find_by!(account_number: '2400')
    expect(settings.update(customer_deposits_account_id: header.id)).to be(false)
    expect(settings.update(customer_deposits_account_id: deposits.id)).to be(true)
  end
end
