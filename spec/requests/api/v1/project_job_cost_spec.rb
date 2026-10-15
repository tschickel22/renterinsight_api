# frozen_string_literal: true

require 'rails_helper'

# E68 step 3: the job a bill is for goes onto its ledger lines and its job
# cost, and two reports read it back.
RSpec.describe 'Projects on bills, journal lines and job cost reports', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') } # seeds the chart of accounts
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:account) { company.accounts.create!(name: 'Diaz') }
  let(:deal) { company.deals.create!(name: 'Diaz home', account: account, selling_price: 100_000) }
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active', deal: deal, budget_amount: 10_000) }
  let!(:set_phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, estimated_budget: 6000) }
  let(:other_project) { company.projects.create!(name: 'Lopez home', status: 'active') }
  let(:installer) { Contractor.create!(company: company, name: 'Smith Set-Up', status: 'active') }
  let(:expense) { company.chart_of_accounts.where(account_type: 'expense', is_header: false, is_active: true).order(:account_number).first }

  def body = JSON.parse(response.body)

  def create_bill(status: 'pending', project_id: project.id, lines: nil, tax: 0)
    lines ||= [{ chart_of_account_id: expense.id, amount: 4000, description: 'Set and level' }]
    post '/api/v1/bills', headers: headers, params: {
      bill: { vendor_id: installer.id, bill_date: Date.current.to_s, status: status, project_id: project_id,
              tax_amount: tax, bill_line_items_attributes: lines }
    }.to_json
    expect(response).to have_http_status(:created), response.body
    company.bills.find(body['id'])
  end

  describe 'a bill for a job' do
    it 'tags its ledger debit with the project and its deal, and adds the job cost once' do
      bill = create_bill

      debit, = bill.journal_entry.journal_entry_lines.where('debit_amount > 0').to_a
      ap = bill.journal_entry.journal_entry_lines.find_by('credit_amount > 0')
      expect(debit).to have_attributes(project_id: project.id, deal_id: deal.id)
      expect(ap.project_id).to be_nil

      items = project.project_cost_items.not_deleted
      expect(items.count).to eq(1)
      expect(items.first).to have_attributes(amount: 4000, status: 'approved', bill_id: bill.id, cost_type: 'subcontractor')
      expect(project.reload.actual_cost).to eq(4000)
    end

    it 'splits one bill across two jobs, tax included' do
      bill = create_bill(tax: 100, lines: [
        { chart_of_account_id: expense.id, amount: 3000, description: 'Diaz set' },
        { chart_of_account_id: expense.id, amount: 1000, description: 'Lopez trim', project_id: other_project.id }
      ])

      expect(project.project_cost_items.not_deleted.sum(:amount)).to eq(3075)
      expect(other_project.project_cost_items.not_deleted.sum(:amount)).to eq(1025)
      expect(bill.journal_entry.journal_entry_lines.where(project_id: other_project.id).sum(:debit_amount)).to eq(1025)
    end

    it 'counts nothing while a draft, and the cost when it posts' do
      bill = create_bill(status: 'draft')
      expect(project.project_cost_items.count).to eq(0)

      patch "/api/v1/bills/#{bill.id}", headers: headers, params: { bill: { status: 'pending' } }.to_json
      expect(project.project_cost_items.not_deleted.sum(:amount)).to eq(4000)
    end

    it 'moves the ledger tag and the job cost when a posted bill is retagged' do
      bill = create_bill
      line = bill.bill_line_items.first

      patch "/api/v1/bills/#{bill.id}", headers: headers, params: {
        bill: { project_id: other_project.id, bill_line_items_attributes: [{ id: line.id, project_id: other_project.id }] }
      }.to_json
      expect(response).to have_http_status(:ok), response.body

      expect(bill.journal_entry.journal_entry_lines.where('debit_amount > 0').pluck(:project_id, :deal_id)).to eq([[other_project.id, nil]])
      expect(project.project_cost_items.not_deleted.count).to eq(0)
      expect(other_project.project_cost_items.not_deleted.sum(:amount)).to eq(4000)
    end

    it 'leaves a bill that already has its cost line alone' do
      item = project.project_cost_items.create!(company_id: company.id, description: 'Set', amount: 4000, cost_type: 'subcontractor',
                                                vendor_id: installer.id, status: 'pending')
      bill = create_bill(status: 'draft')
      item.update!(bill_id: bill.id)

      patch "/api/v1/bills/#{bill.id}", headers: headers, params: { bill: { status: 'pending' } }.to_json
      expect(project.project_cost_items.not_deleted.count).to eq(1)
      expect(item.reload.status).to eq('approved')
    end

    it "refuses another company's project on the bill or a line" do
      foreign = create(:company).projects.create!(name: 'Not yours', status: 'active')

      post '/api/v1/bills', headers: headers, params: {
        bill: { vendor_id: installer.id, bill_date: Date.current.to_s, status: 'draft', project_id: foreign.id,
                bill_line_items_attributes: [{ chart_of_account_id: expense.id, amount: 10 }] }
      }.to_json
      expect(response).to have_http_status(:unprocessable_entity)

      post '/api/v1/bills', headers: headers, params: {
        bill: { vendor_id: installer.id, bill_date: Date.current.to_s, status: 'draft',
                bill_line_items_attributes: [{ chart_of_account_id: expense.id, amount: 10, project_id: foreign.id }] }
      }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'journal entry lines' do
    let(:bank) { company.chart_of_accounts.where(account_type: 'asset', is_header: false).order(:account_number).first }

    def post_entry(line_extra)
      post '/api/v1/journal_entries', headers: headers, params: {
        journal_entry: { entry_date: Date.current.to_s, memo: 'Job cost',
                         journal_entry_lines_attributes: [
                           { chart_of_account_id: expense.id, debit_amount: 50, credit_amount: 0 }.merge(line_extra),
                           { chart_of_account_id: bank.id, debit_amount: 0, credit_amount: 50 }
                         ] }
      }.to_json
    end

    it 'takes a project per line' do
      post_entry(project_id: project.id)
      expect(response).to have_http_status(:created), response.body
      expect(JournalEntryLine.where(project_id: project.id).sum(:debit_amount)).to eq(50)
    end

    it "refuses another company's project or deal" do
      other = create(:company)
      post_entry(project_id: other.projects.create!(name: 'X', status: 'active').id)
      expect(response).to have_http_status(:unprocessable_entity)

      post_entry(deal_id: other.deals.create!(name: 'X', account: other.accounts.create!(name: 'Y')).id)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'reports' do
    before do
      allow_any_instance_of(Deal).to receive(:front_gross).and_return(BigDecimal('20000'))
      create_bill # 4000 billed, Set phase
      project.project_cost_items.first.update!(project_phase_id: set_phase.id)
      project.project_cost_items.create!(company_id: company.id, project_phase_id: set_phase.id, description: 'Skirting',
                                         amount: 1500, cost_type: 'materials', status: 'pending')
      project.project_cost_items.create!(company_id: company.id, description: 'Permit', amount: 300, cost_type: 'permit', status: 'paid')
      project.project_cost_items.create!(company_id: company.id, description: 'Wrong crew', amount: 900, cost_type: 'labor', status: 'disputed')
    end

    it 'shows profit after job cost, without the disputed line' do
      get '/api/v1/accounting/reports/project_profitability', headers: headers
      row = body['projects'].find { |r| r['id'] == project.id }

      expect(row).to include('sale_price' => 100_000.0, 'front_gross' => 20_000.0, 'job_cost' => 5800.0, 'disputed' => 900.0,
                             'budget_variance' => 4200.0, 'after_job_cost' => 14_200.0, 'margin' => 14.2, 'on_books' => 4000.0)
    end

    it 'hides the gross from someone who may not see dealer cost' do
      allow_any_instance_of(User).to receive(:has_permission?).and_call_original
      allow_any_instance_of(User).to receive(:has_permission?).with('deals', 'read', scope: 'view_cost_details').and_return(false)

      get '/api/v1/accounting/reports/project_profitability', headers: headers
      row = body['projects'].find { |r| r['id'] == project.id }
      expect(row).not_to include('front_gross', 'after_job_cost', 'margin')
      expect(row['job_cost']).to eq(5800.0)
      expect(body['can_view_costs']).to be(false)
    end

    it 'splits cost into committed, billed and paid by phase' do
      get '/api/v1/accounting/reports/project_budget', headers: headers
      row = body['projects'].find { |r| r['id'] == project.id }

      expect(row).to include('name' => 'Diaz home', 'budget' => 10_000.0, 'committed' => 1500.0, 'billed' => 4000.0, 'paid' => 300.0,
                             'disputed' => 900.0, 'total' => 5800.0, 'remaining' => 4200.0)
      set = row['phases'].find { |p| p['name'] == 'Set' }
      expect(set).to include('budget' => 6000.0, 'committed' => 1500.0, 'billed' => 4000.0, 'remaining' => 500.0)
      expect(row['phases'].find { |p| p['name'] == 'No phase' }).to include('paid' => 300.0, 'disputed' => 900.0)
    end

    it 'counts a voided bill as disputed' do
      company.bills.last.void!
      get '/api/v1/accounting/reports/project_budget', headers: headers
      row = body['projects'].find { |r| r['id'] == project.id }
      expect(row).to include('billed' => 0.0, 'disputed' => 4900.0)
    end
  end
end
