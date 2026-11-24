# frozen_string_literal: true

require 'rails_helper'

# Commission is booked once, when the deal is approved to the books (Tom,
# 2026-11-24). It used to be booked by the closing entry when the deal
# already had a commission amount, and again by Approve on the Commission
# Approval tab, to other accounts: $9,262.05 counted twice on staging.
RSpec.describe 'Deal commission booking', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') } # seeds the chart of accounts
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'user', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:ar) do
    company.chart_of_accounts.create!(account_number: '1190', name: 'Accounts Receivable', account_type: 'asset',
                                      sub_type: 'accounts_receivable', normal_balance: 'debit')
  end
  let(:revenue) do
    company.chart_of_accounts.create!(account_number: '4090', name: 'Sales Revenue', account_type: 'revenue', normal_balance: 'credit')
  end
  let(:plan) { company.commission_plans.create!(name: 'Sales', is_active: true) }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz') }
  let(:deal) do
    company.deals.create!(location: location, contact_id: buyer.id, name: 'Diaz home', selling_price: 100_000, home_cost: 80_000,
                          actual_close_date: Date.current, stage: 'closed_won', owner_id: rep.id,
                          primary_salesperson_id: rep.id, commission_plan_id: plan.id)
  end
  let(:commission_expense) { company.chart_of_accounts.find_by!(account_number: '6010') }
  let(:accrued) { company.chart_of_accounts.find_by!(account_number: '2020') }

  before do
    AccountingSettings.for_company(company).update!(default_ar_account: ar, default_sales_revenue_account: revenue, auto_post_deals: false)
    company.commission_components.create!(commission_plan: plan, is_active: true, applies_to_role: 'primary_salesperson',
                                          name: 'Flat', component_type: 'flat_per_unit', flat_amount: 1_500)
  end

  def body = JSON.parse(response.body)

  def balance(account)
    JournalEntryLine.joins(:journal_entry).where(journal_entries: { company_id: company.id, is_void: false })
                    .where(chart_of_account_id: account.id).sum('debit_amount - credit_amount').to_d
  end

  def approve_deal
    post "/api/v1/deal_approvals/#{deal.id}/approve", headers: headers, params: {}.to_json
    expect(response).to have_http_status(:ok), response.body
  end

  it 'books commission once at approval, for a company that pays at accounting approval' do
    approve_deal
    expect(deal.reload.commission_posted).to be(true)
    expect(balance(commission_expense)).to eq(1_500)
    expect(balance(accrued)).to eq(-1_500)

    closing = JournalEntry.find(deal.gl_journal_entry_id)
    expect(closing.journal_entry_lines.where(chart_of_account_id: commission_expense.id)).to be_empty
  end

  it 'never books it twice when commission is approved afterwards' do
    approve_deal
    post "/api/v1/deal_approvals/#{deal.id}/approve_commission", headers: headers, params: {}.to_json
    expect(body['error']).to eq('Commission already posted')
    expect(balance(commission_expense)).to eq(1_500)
    expect(company.chart_of_accounts.where('name ILIKE ?', '%commission payable%')).to be_empty
  end

  it 'books commission the deal had before approval once too (a company that pays at close)' do
    CommissionSettings.set_payable_at(company, CommissionSettings::DEAL_CLOSED)
    deal.generate_commission_payments!
    expect(deal.reload.commission_amount.to_d).to eq(1_500)

    approve_deal
    expect(balance(commission_expense)).to eq(1_500)
  end

  it 'books only the difference when an adjustment changes what is owed after approval' do
    approve_deal
    company.commission_adjustments.create!(deal: deal, payee: rep, amount: 500, reason: 'Promised bonus')
    CommissionPaymentGeneratorService.new(deal.reload).recalculate
    owed = CommissionPayment.where(deal_id: deal.id).where.not(status: %w[reversed cancelled]).sum(:amount).to_d
    expect(owed).to eq(2_000)
    expect(balance(commission_expense)).to eq(2_000)
    expect(JournalEntry.where(company_id: company.id).where('memo LIKE ?', 'Commission accrual change%').count).to eq(1)

    pending = CommissionPayment.where(deal_id: deal.id, status: 'pending').first
    if pending
      pending.cancel!
      expect(balance(commission_expense)).to eq(owed - pending.amount)
    end
  end

  it 'counts commission an old entry already booked, so a re-sync books nothing more' do
    approve_deal
    accrual = Accounting::DealCommissionAccrual.new(deal.reload)
    expect(accrual.sync![:unchanged]).to be(true)
    expect(JournalEntry.where(company_id: company.id).where('memo LIKE ?', 'Commission accrual%').count).to eq(1)
  end
end
