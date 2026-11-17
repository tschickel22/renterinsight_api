# frozen_string_literal: true

require 'rails_helper'

# A deal with a selling price and no home cost used to post anyway: revenue with no
# cost of goods, the home left in inventory, and commission paid on the whole price.
# Every posting path now refuses it, and the approvals queue says why.
RSpec.describe 'Posting a deal needs a home cost', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') } # seeds the chart of accounts
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:account) { company.accounts.create!(name: 'Diaz') }
  let(:ar) do
    company.chart_of_accounts.create!(account_number: '1190', name: 'Accounts Receivable', account_type: 'asset',
                                      sub_type: 'accounts_receivable', normal_balance: 'debit')
  end
  let(:revenue) do
    company.chart_of_accounts.create!(account_number: '4090', name: 'Sales Revenue', account_type: 'revenue', normal_balance: 'credit')
  end
  let(:auto_post) { false }

  before do
    AccountingSettings.for_company(company).update!(default_ar_account: ar, default_sales_revenue_account: revenue, auto_post_deals: auto_post)
  end

  def body = JSON.parse(response.body)

  def closed_deal(**attrs)
    company.deals.create!({ location: location, account: account, name: 'Diaz home', selling_price: 100_000,
                            actual_close_date: Date.current, stage: 'closed_won' }.merge(attrs))
  end

  it 'refuses to approve a deal with a price and no cost, and posts nothing' do
    deal = closed_deal

    post "/api/v1/deal_approvals/#{deal.id}/approve", headers: headers, params: {}.to_json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['code']).to eq('cost_not_entered')
    expect(body['error']).to include('no home cost')
    expect(deal.reload.gl_posted).to be_falsey
    expect(company.journal_entries.where(source_entity: deal)).to be_empty
  end

  it 'shows the reason on the deal in the approvals queue and counts it' do
    missing = closed_deal
    costed = closed_deal(name: 'Costed home', home_cost: 70_000)

    get '/api/v1/deal_approvals/pending', headers: headers
    rows = body['deals'].index_by { |r| r['id'] }
    expect(rows[missing.id]['posting_problem']).to include('no home cost')
    expect(rows[costed.id]['posting_problem']).to be_nil

    get '/api/v1/deal_approvals/stats', headers: headers
    expect(body['pending_missing_cost']).to eq(1)
  end

  it 'approves once the cost is entered, with a cost of goods line' do
    deal = closed_deal(home_cost: 70_000)

    post "/api/v1/deal_approvals/#{deal.id}/approve", headers: headers, params: {}.to_json

    expect(response).to have_http_status(:ok)
    expect(deal.reload.gl_posted).to be(true)
    cogs = JournalEntry.find(deal.gl_journal_entry_id).journal_entry_lines.where('debit_amount > 0').sum(:debit_amount)
    expect(cogs).to be >= 170_000 # receivable 100,000 plus cost of goods 70,000
  end

  it 'refuses the Post to GL button too' do
    deal = closed_deal

    post "/api/v1/deals/#{deal.id}/accounting/post_closing", headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['code']).to eq('cost_not_entered')
  end

  context 'with auto-post on' do
    let(:auto_post) { true }

    it 'leaves a deal with no cost unposted in the queue' do
      deal = closed_deal
      expect(deal.reload.gl_posted).to be_falsey
    end
  end

  it 'still posts a deal with no selling price' do
    expect(Accounting::DealAccountingService.new(closed_deal(selling_price: 0)).missing_cost_problem).to be_nil
  end
end
