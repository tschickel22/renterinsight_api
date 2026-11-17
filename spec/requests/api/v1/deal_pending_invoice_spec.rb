# frozen_string_literal: true

require 'rails_helper'

# A closed deal gets its sale invoice as a draft right away, follows the deal,
# takes no payments, and approval takes it over instead of making a second one.
RSpec.describe 'Deal sale invoice awaiting approval', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:account) { company.accounts.create!(name: 'Diaz') }
  let(:contact) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz', email: 'ana@example.com') }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:ar) do
    company.chart_of_accounts.create!(account_number: '1190', name: 'Accounts Receivable', account_type: 'asset',
                                      sub_type: 'accounts_receivable', normal_balance: 'debit')
  end
  let(:revenue) do
    company.chart_of_accounts.create!(account_number: '4090', name: 'Sales Revenue', account_type: 'revenue', normal_balance: 'credit')
  end
  let(:deal) do
    company.deals.create!(location: location, name: 'Diaz home', account: account, contact: contact, selling_price: 100_000, home_cost: 1,
                          actual_close_date: Date.current, stage: 'negotiation', payment_type: 'cash')
  end

  before do
    AccountingSettings.for_company(company).update!(default_ar_account: ar, default_sales_revenue_account: revenue,
                                                    auto_post_deals: false, auto_post_invoices: true)
  end

  def body = JSON.parse(response.body)

  def pending = company.invoices.awaiting_deal_approval.find_by(source_id: deal.id)

  def ar_balance
    JournalEntryLine.joins(:journal_entry).merge(JournalEntry.in_ledger)
                    .where(journal_entries: { company_id: company.id }, chart_of_account_id: ar.id)
                    .sum('debit_amount - credit_amount').to_d
  end

  def close! = deal.update!(stage: 'closed_won')

  it 'makes a draft when the deal closes that books nothing and follows the deal' do
    expect(pending).to be_nil
    close!
    inv = pending
    expect(inv).to have_attributes(status: 'draft', deal_id: deal.id, contact_id: contact.id, total: 100_000)
    expect(inv.invoice_items.map { |i| i.cost.to_d }).to all(be_zero) # never the dealer's cost
    expect(deal.reload.deal_invoice_id).to be_nil
    expect(ar_balance).to eq(0)

    deal.update!(selling_price: 104_000)
    expect(inv.reload.total).to eq(104_000)
    expect(inv.invoice_items.count).to eq(1)
  end

  it 'refuses edits, finalizing and payments on the invoice, but takes a note and sends it as a draft' do
    close!
    inv = pending

    put "/api/v1/invoices/#{inv.id}", headers: headers, params: { invoice: { due_date: Date.current + 5 } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['code']).to eq('awaiting_deal_approval')

    put "/api/v1/invoices/#{inv.id}", headers: headers, params: { invoice: { notes: 'Thanks!' } }.to_json
    expect(response).to have_http_status(:ok), response.body

    post "/api/v1/invoices/#{inv.id}/finalize", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)

    inv.mark_as_sent!
    expect(inv.reload).to have_attributes(status: 'draft')
    expect(inv.sent_at).to be_present
    expect(inv.update(status: 'sent')).to be(false)

    get "/api/v1/invoices/#{inv.id}", headers: headers
    expect(body['awaiting_deal_approval']).to be(true)
  end

  it 'is taken over by approval: same invoice, sent, the sale booked once' do
    close!
    inv = pending

    get "/api/v1/deal_approvals/#{deal.id}", headers: headers
    expect(body.dig('funding', 'other_invoices')).to eq([])
    expect(body.dig('funding', 'pending_invoice', 'id')).to eq(inv.id)

    post "/api/v1/deal_approvals/#{deal.id}/approve", headers: headers,
                                                     params: { funding: { plan: { type: 'single', due_date: Date.current.to_s } } }.to_json
    expect(response).to have_http_status(:ok), response.body
    expect(body['deal_invoice_id']).to eq(inv.id)
    expect(inv.reload).to have_attributes(status: 'sent', total: 100_000)
    expect(company.invoices.where(deal_id: deal.id).count).to eq(1)
    expect(ar_balance).to eq(100_000)
  end

  it 'cancels the draft when the deal reopens, and makes a fresh one when it closes again' do
    close!
    first = pending
    deal.update!(stage: 'negotiation')
    expect(first.reload.status).to eq('cancelled')
    close!
    expect(pending.id).not_to eq(first.id)
  end

  it 'keeps a draft for a deal closed long ago a draft, not overdue' do
    deal.update!(actual_close_date: Date.current - 60)
    close!
    expect(pending).to have_attributes(status: 'draft')
    deal.update!(selling_price: 101_000)
    expect(pending).to have_attributes(status: 'draft', total: 101_000)
  end

  it 'makes no draft for a company that posts deals as they close' do
    AccountingSettings.for_company(company).update!(auto_post_deals: true)
    close!
    expect(pending).to be_nil
  end
end
