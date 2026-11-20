# frozen_string_literal: true

require 'rails_helper'

# E109: a cost typed on the project says how it was paid. Not paid yet makes
# a draft bill, already paid records the expense, tracking only stays out of
# the books. Status follows the bill or the entry, and the job is never
# charged twice for one cost.
RSpec.describe 'Project costs: how they were paid', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:account) { company.accounts.create!(name: 'Garcia') }
  let(:deal) { company.deals.create!(name: 'Garcia home', account: account, selling_price: 100_000) }
  let(:project) { company.projects.create!(name: 'Garcia set', status: 'active', deal: deal, budget_amount: 18_500) }
  let!(:site) { project.project_phases.create!(company: company, name: 'Site prep', position: 0, estimated_budget: 4000) }
  let!(:skirting) { project.project_phases.create!(company: company, name: 'Skirting', position: 1, estimated_budget: 14_000) }
  let(:supplier) { Contractor.create!(company: company, name: 'Front Range Supply', status: 'active') }
  let(:expense) { company.chart_of_accounts.where(account_type: 'expense', is_header: false, is_active: true).order(:account_number).first }
  let(:card_gl) do
    company.chart_of_accounts.create!(account_number: '2190', name: 'Company Visa', account_type: 'liability',
                                      normal_balance: 'credit', is_active: true, is_header: false)
  end
  let!(:card) do
    company.bank_accounts.create!(bank_name: 'Company Visa', account_type: 'credit_card', account_purpose: 'sync_only', chart_of_account: card_gl)
  end

  def body = JSON.parse(response.body)
  def posting_on! = Setting.set('company', company.id, 'project_management', { 'cost_lines_post_via_bills' => true })
  def items = project.project_cost_items.not_deleted

  def add_cost(**params)
    post "/api/v1/projects/#{project.id}/cost_items", headers: headers,
         params: { description: 'Skirting', amount: 1140, cost_type: 'materials', project_phase_id: skirting.id }.merge(params).to_json
  end

  describe 'not paid yet' do
    before { posting_on! }

    it 'makes a draft bill, and Approve on the line posts it' do
      add_cost(pay_mode: 'bill', contractor_id: supplier.id)
      expect(response).to have_http_status(:created), response.body
      expect(body).to include('pay_mode' => 'bill', 'status' => 'pending', 'source_label' => 'Typed on the project, draft bill')
      bill = company.bills.find(body['bill_id'])
      expect(bill.status).to eq('draft')

      post "/api/v1/projects/#{project.id}/cost_items/#{body['id']}/approve", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(bill.reload.status).to eq('pending')
      expect(bill.journal_entry).to be_present
      expect(body['status']).to eq('approved')
    end

    it 'asks for a vendor instead of quietly making no bill' do
      add_cost(pay_mode: 'bill')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to include('Pick the vendor')
      expect(items.count).to eq(0)
    end

    it 'deletes its draft bill with it, and refuses once the bill is approved' do
      add_cost(pay_mode: 'bill', contractor_id: supplier.id)
      id = body['id']
      bill = company.bills.find(body['bill_id'])
      delete "/api/v1/projects/#{project.id}/cost_items/#{id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(bill.reload.is_deleted).to be(true)

      add_cost(pay_mode: 'bill', contractor_id: supplier.id)
      id = body['id']
      post "/api/v1/projects/#{project.id}/cost_items/#{id}/approve", headers: headers
      delete "/api/v1/projects/#{project.id}/cost_items/#{id}", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to include('Void or delete the bill')
    end

    it "won't take a status from the form once a bill is behind it" do
      add_cost(pay_mode: 'bill', contractor_id: supplier.id)
      patch "/api/v1/projects/#{project.id}/cost_items/#{body['id']}", headers: headers, params: { status: 'paid' }.to_json
      expect(body['status']).to eq('pending')
    end
  end

  describe 'already paid' do
    before { posting_on! }

    it 'records the expense on the card and the line is Paid, once' do
      add_cost(pay_mode: 'paid', contractor_id: supplier.id, payment_account_id: card_gl.id, category_account_id: expense.id,
               project_phase_id: site.id, description: 'Permit', amount: 425)
      expect(response).to have_http_status(:created), response.body
      expect(body).to include('pay_mode' => 'paid', 'status' => 'paid', 'project_phase_id' => site.id)

      je = JournalEntry.find(body['journal_entry_id'])
      expect(je.source_type).to eq('quick_entry')
      expect(je.journal_entry_lines.find_by(chart_of_account: expense)).to have_attributes(debit_amount: 425, project_id: project.id, deal_id: deal.id)
      expect(je.journal_entry_lines.find_by(chart_of_account: card_gl).credit_amount).to eq(425)
      expect(items.count).to eq(1)
      expect(project.reload.actual_cost).to eq(425)
    end

    it 'needs the account it was paid from' do
      add_cost(pay_mode: 'paid', amount: 425)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to include('paid from')
      expect(items.count).to eq(0)
    end

    it 'is caught on the card feed a few days later instead of posting twice' do
      add_cost(pay_mode: 'paid', payment_account_id: card_gl.id, category_account_id: expense.id, amount: 425, date: '2026-11-18')
      txn = company.bank_transactions.create!(bank_account: card, description: 'WELD COUNTY', amount: -425,
                                              transaction_date: Date.new(2026, 11, 20), status: 'unmatched')
      Current.set(user: dealer, company_id: company.id) do
        expect { txn.categorize!(account: expense, create_je: true, project: project) }
          .to raise_error(BankTransaction::AlreadyBooked, /already job cost on Garcia set/)
      end
    end
  end

  describe 'tracking only' do
    it 'is all a company without posting gets, and asks for the books to be done in Accounting' do
      add_cost(pay_mode: 'paid', payment_account_id: card_gl.id)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to include('tracking only')

      add_cost(contractor_id: supplier.id)
      expect(response).to have_http_status(:created)
      expect(body).to include('pay_mode' => 'track', 'bill_id' => nil, 'status' => 'approved')
      expect(project.reload.actual_cost).to eq(1140)
    end

    it 'is taken over by the vendor bill when it is entered later, not counted twice' do
      add_cost(contractor_id: supplier.id)
      typed_id = body['id']
      get "/api/v1/projects/#{project.id}/cost_items/duplicates", headers: headers, params: { contractor_id: supplier.id, amount: 1140 }
      expect(body['duplicates'].map { |d| d['id'] }).to eq([typed_id])

      post '/api/v1/bills', headers: headers, params: {
        bill: { vendor_id: supplier.id, bill_date: Date.current.to_s, status: 'pending', project_id: project.id,
                bill_line_items_attributes: [{ chart_of_account_id: expense.id, amount: 1140, description: 'Skirting' }] }
      }.to_json
      expect(response).to have_http_status(:created), response.body
      expect(items.count).to eq(1)
      expect(items.first).to have_attributes(id: typed_id, bill_id: body['id'], status: 'approved', project_phase_id: skirting.id)
    end
  end

  describe 'budget' do
    it 'says how much of the project budget is not on a phase' do
      get "/api/v1/projects/#{project.id}/cost_items/summary", headers: headers
      expect(body['project']).to include('phase_budget_total' => '18000.0', 'budget_not_on_phase' => '500.0')
    end
  end

  describe 'the bank feed' do
    it 'stops a withdrawal that pays an open bill on the job from being categorized as cost again' do
      bill = company.bills.create!(vendor_id: supplier.id, project: project, bill_date: Date.current, status: 'draft',
                                   bill_line_items_attributes: [{ chart_of_account_id: expense.id, amount: 1850, description: 'Meter' }])
      bill.update!(status: 'pending')
      checking_gl = company.chart_of_accounts.create!(account_number: '1990', name: 'Checking', account_type: 'asset',
                                                      normal_balance: 'debit', is_active: true, is_header: false)
      bank = company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: checking_gl)
      txn = company.bank_transactions.create!(bank_account: bank, description: 'FRONT RANGE', amount: -1850,
                                              transaction_date: Date.current, status: 'unmatched')
      Current.set(user: dealer, company_id: company.id) do
        expect { txn.categorize!(account: expense, create_je: true, project: project) }
          .to raise_error(BankTransaction::PaysOpenBill, /bill #{bill.bill_number}/)
        txn.categorize!(account: expense, create_je: true, project: project, not_a_bill_payment: true)
      end
      expect(txn.reload.status).to eq('matched')
    end
  end
end
