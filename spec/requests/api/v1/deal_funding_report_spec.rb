# frozen_string_literal: true

require 'rails_helper'

# E78 step 1: what each approved deal sold for, has received and still owes.
RSpec.describe 'Deal Funding report', type: :request do
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

  let(:bank_gl) { company.chart_of_accounts.where(account_type: 'asset', is_header: false).order(:account_number).first }
  let(:bank) { company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: bank_gl) }

  before do
    AccountingSettings.for_company(company).update!(default_ar_account: ar, default_sales_revenue_account: revenue, auto_post_deals: false)
  end

  def body = JSON.parse(response.body)

  def approved_deal(price: 100_000, name: 'Diaz home')
    deal = company.deals.create!(location: location, name: name, account: account, selling_price: price, actual_close_date: Date.current - 40)
    deal.update!(stage: 'closed_won')
    result = Accounting::DealAccountingService.new(deal).post_closing_entries!(user: dealer)
    expect(result).to include(success: true), result.inspect
    deal.reload
  end

  def report(**params)
    get '/api/v1/accounting/reports/deal_funding', headers: headers, params: params
    expect(response).to have_http_status(:ok), response.body
    body
  end

  it 'shows amount, received, owed and late draws, filling draws in the order paid' do
    deal = approved_deal
    invoice = DealInvoiceService.new(deal, user: dealer).create_invoice!
    invoice.update_columns(draw_schedule: { 'draws' => [
      { 'position' => 1, 'description' => 'Down payment', 'amount' => 10_000, 'due_date' => (Date.current - 30).to_s, 'status' => 'pending', 'paid_amount' => 0 },
      { 'position' => 2, 'description' => 'At delivery', 'amount' => 90_000, 'due_date' => (Date.current + 30).to_s, 'status' => 'pending', 'paid_amount' => 0 }
    ] })

    post "/api/v1/deals/#{deal.id}/record_payment", headers: headers,
                                                   params: { amount: 4000, payment_date: Date.current.to_s, bank_account_id: bank.id }.to_json
    expect(response).to have_http_status(:ok), response.body

    row = report['deals'].find { |r| r['id'] == deal.id }
    expect(row).to include('deal_amount' => 100_000.0, 'received' => 4000.0, 'owed' => 96_000.0,
                           'overdue_amount' => 6000.0, 'overdue_draws' => 1, 'status' => 'overdue', 'books_check' => 'ok')
    expect(row['next_draw']).to include('description' => 'Down payment', 'balance' => 6000.0)
    expect(body['summary']).to include('total_owed' => 96_000.0, 'total_overdue' => 6000.0, 'received_this_month' => 4000.0)

    expect(report(status: 'paid')['deals']).to be_empty
    expect(report(status: 'overdue')['deals'].map { |r| r['id'] }).to eq([deal.id])
  end

  it 'flags a deal with no invoice, and an invoice the books disagree with' do
    bare = approved_deal(name: 'No invoice')
    invoiced = approved_deal(price: 50_000, name: 'Short invoice')
    DealInvoiceService.new(invoiced).create_invoice!.update_columns(total: 49_000, amount_due: 49_000)

    rows = report['deals'].index_by { |r| r['id'] }
    expect(rows[bare.id]).to include('status' => 'no_invoice', 'books_check' => 'no_invoice', 'deal_amount' => 100_000.0)
    expect(rows[invoiced.id]).to include('books_check' => 'differs', 'books_difference' => 1000.0)
    expect(body['summary']).to include('books_issue_count' => 1, 'no_invoice_count' => 1, 'no_invoice_amount' => 100_000.0,
                                       'total_owed' => 49_000.0)
  end

  it 'invoices an approved deal that never got one, and only an approved one' do
    bare = approved_deal
    post "/api/v1/deals/#{bare.id}/create_invoice", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(bare.reload.deal_invoice_id).to eq(body.dig('invoice', 'id'))
    expect(report['deals'].find { |r| r['id'] == bare.id }).to include('status' => 'overdue', 'books_check' => 'ok')

    open_deal = company.deals.create!(location: location, name: 'Open', account: account, selling_price: 10)
    post "/api/v1/deals/#{open_deal.id}/create_invoice", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'bills the sales tax posted at approval when the deal sheet tax is 0' do
    deal = company.deals.create!(location: location, name: 'Taxed', account: account, selling_price: 50_000, tax_amount: 0, total_tax_amount: 1450)
    expect(DealInvoiceService.new(deal).deal_total).to eq(51_450)
  end

  it 'gives an auto-posted deal its invoice' do
    AccountingSettings.for_company(company).update!(auto_post_deals: true)
    deal = company.deals.create!(location: location, name: 'Auto', account: account, selling_price: 70_000)
    deal.update!(stage: 'closed_won')

    expect(deal.reload.gl_posted_at).to be_present
    expect(company.invoices.find(deal.deal_invoice_id).total).to eq(70_000)
  end

  it "lists a deal's invoice on its Invoices tab whatever location is picked" do
    deal = approved_deal
    invoice = DealInvoiceService.new(deal).create_invoice!
    other = company.locations.create!(name: 'Other lot')
    company.invoices.create!(location: other, contact: company.contacts.create!(first_name: 'Z', email: "z-#{SecureRandom.hex(3)}@example.com"),
                             invoice_number: "INV-X-#{SecureRandom.hex(2)}", invoice_date: Date.current, due_date: Date.current, status: 'sent')

    get '/api/v1/invoices', headers: headers.merge('X-Location-ID' => other.id.to_s), params: { deal_id: deal.id }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).map { |i| i['id'] }).to eq([invoice.id])

    get '/api/v1/invoices', headers: headers.merge('X-Location-ID' => other.id.to_s)
    expect(JSON.parse(response.body).map { |i| i['id'] }).not_to include(invoice.id)
  end

  it 'bills every line item approval books, and matches an older invoice to the books' do
    deal = company.deals.create!(location: location, name: 'With F&I', account: account, selling_price: 50_000,
                                 actual_close_date: Date.current)
    deal.deal_products.create!(product_name: 'Installation', quantity: 1, unit_price: 5000, discount: 0, total: 5000, notes: 'category:fi')
    deal.update!(stage: 'closed_won')
    expect(Accounting::DealAccountingService.new(deal).post_closing_entries!(user: dealer)).to include(success: true)

    invoice = DealInvoiceService.new(deal.reload).create_invoice!
    expect(invoice.total).to eq(55_000)
    expect(report['deals'].find { |r| r['id'] == deal.id }['books_check']).to eq('ok')

    # An invoice made before the fix left the product off.
    invoice.update_columns(total: 50_000, amount_due: 50_000)
    expect(report['deals'].find { |r| r['id'] == deal.id }).to include('books_check' => 'differs', 'books_difference' => 5000.0)

    post "/api/v1/deals/#{deal.id}/sync_invoice", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(invoice.reload).to have_attributes(total: 55_000, amount_due: 55_000)
    expect(report['deals'].find { |r| r['id'] == deal.id }['books_check']).to eq('ok')
  end

  describe 'a payment recorded on the invoice page' do
    let(:deal) { approved_deal(price: 40_000, name: 'Invoice page') }
    let!(:invoice) { DealInvoiceService.new(deal).create_invoice! }

    it 'posts to the books for a deal invoice, and fills its draws' do
      post "/api/v1/invoices/#{invoice.id}/mark_paid", headers: headers,
                                                      params: { amount: 5000, bank_account_id: bank.id, payment_method: 'check', reference_number: '1201' }.to_json
      expect(response).to have_http_status(:ok), response.body
      receipt = company.cash_receipts.find_by!(deal_id: deal.id)
      expect(receipt.journal_entry).to be_present
      expect(invoice.reload.amount_due).to eq(35_000)
      expect(report['deals'].find { |r| r['id'] == deal.id }).to include('received' => 5000.0, 'books_check' => 'ok')

      get "/api/v1/invoices/#{invoice.id}", headers: headers
      expect(JSON.parse(response.body).dig('invoice', 'is_deal_invoice') || JSON.parse(response.body)['is_deal_invoice']).to be(true)
    end

    it 'flags a payment that never posted, and posts it into the bank picked' do
      AccountingSettings.for_company(company).update!(auto_post_payments: false)
      invoice.update_columns(contact_id: company.contacts.create!(first_name: 'Ana', email: "ana-#{SecureRandom.hex(3)}@example.com").id)
      # What the invoice page's Record Payment did before: a payment record only.
      expect(invoice.record_payment!(5000, 'manual', { notes: 'check 1201' })).to be_truthy
      expect(invoice.reload.amount_paid).to eq(5000)

      row = report['deals'].find { |r| r['id'] == deal.id }
      expect(row).to include('books_check' => 'unposted_payment', 'unposted_payments' => 5000.0)

      post "/api/v1/deals/#{deal.id}/post_invoice_payments", headers: headers, params: { bank_account_id: bank.id }.to_json
      expect(response).to have_http_status(:ok), response.body
      expect(body['posted']).to eq(1)
      expect(report['deals'].find { |r| r['id'] == deal.id }).to include('books_check' => 'ok', 'unposted_payments' => 0.0)
    end
  end
end
