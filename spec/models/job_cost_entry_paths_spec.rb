# frozen_string_literal: true

require 'rails_helper'

# E109 follow-up (Tom 2026-11-20): every way money is entered in Accounting
# for a job reaches its Costs & Budget list once, with the right status.
#   - A recurring entry can name a job, and each run is job cost on it.
#   - A manual or recurring entry that pays from a bank account is Paid.
#   - A bank rule that posts on its own holds back a line that looks already
#     booked or looks like an open bill's payment, and says why.
RSpec.describe 'Job cost from every entry path' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Ok', password: 'Pass1234!', role: 'admin', status: 'active') }

  def gl!(number, name, type)
    company.chart_of_accounts.create!(account_number: number, name: name, account_type: type,
                                      normal_balance: %w[asset expense].include?(type) ? 'debit' : 'credit',
                                      is_active: true, is_header: false)
  end

  let!(:cash_gl) { gl!('1981', 'Checking', 'asset') }
  let!(:ap_gl) { gl!('2981', 'Accrued', 'liability') }
  let!(:rental) { gl!('6981', 'Equipment rental', 'expense') }
  let!(:bank) { company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: cash_gl) }
  let(:project) { company.projects.create!(name: 'Garcia set', status: 'active') }
  let(:items) { project.project_cost_items.not_deleted }

  around { |ex| Current.set(user: user, company_id: company.id) { ex.run } }

  def recurring!(credit_account)
    company.recurring_journal_entries.create!(
      name: 'Skid steer', frequency: 'monthly', next_run_date: Date.current, is_active: true,
      template_lines: [
        { 'chart_of_account_id' => rental.id, 'debit_amount' => 300, 'credit_amount' => 0, 'project_id' => project.id },
        { 'chart_of_account_id' => credit_account.id, 'debit_amount' => 0, 'credit_amount' => 300 }
      ]
    )
  end

  it 'puts each run of a recurring entry that names a job on that job, Paid when it comes from the bank' do
    je = recurring!(cash_gl).generate_entry!
    expect(je).to be_present
    expect(je.journal_entry_lines.find_by(chart_of_account: rental).project_id).to eq(project.id)
    expect(items.sole).to have_attributes(amount: 300, status: 'paid', journal_entry_id: je.id)
  end

  it 'marks a recurring cost owed when it does not come out of a bank account' do
    recurring!(ap_gl).generate_entry!
    expect(items.sole.status).to eq('approved')
  end

  it 'marks a manual entry that credits the bank Paid' do
    je = company.journal_entries.build(entry_date: Date.current, memo: 'Dumpster', source_type: 'manual', posted_by: user)
    je.journal_entry_lines.build(chart_of_account: rental, debit_amount: 310, credit_amount: 0, project_id: project.id)
    je.journal_entry_lines.build(chart_of_account: cash_gl, debit_amount: 0, credit_amount: 310)
    je.save!
    expect(items.sole).to have_attributes(amount: 310, status: 'paid')
  end

  describe 'a bank rule that posts on its own' do
    let(:service) { BankTransactionMatchingService.new(company) }
    let!(:rule) do
      company.bank_rules.create!(name: 'Yard', match_type: 'contains', match_field: 'description', match_value: 'AGGREGATE',
                                 transaction_direction: 'withdrawal', action_type: 'categorize', assign_account_id: rental.id,
                                 assign_project_id: project.id, auto_confirm: true, priority: 1, is_active: true)
    end

    def txn!(amount, on: Date.current)
      company.bank_transactions.create!(bank_account: bank, description: 'NOCO AGGREGATE', amount: amount, transaction_date: on, status: 'unmatched')
    end

    it 'still posts an ordinary charge to the job' do
      t = txn!(-285)
      service.auto_match(t)
      expect(t.reload).to have_attributes(status: 'matched', matched_by: 'rule', review_reason: nil)
      expect(items.sole).to have_attributes(amount: 285, status: 'paid')
    end

    it 'holds back a charge already recorded as paid a few days before' do
      je = company.journal_entries.build(entry_date: Date.current - 3, memo: 'Gravel', source_type: 'quick_entry', posted_by: user)
      je.journal_entry_lines.build(chart_of_account: rental, debit_amount: 285, credit_amount: 0, project_id: project.id)
      je.journal_entry_lines.build(chart_of_account: cash_gl, debit_amount: 0, credit_amount: 285)
      je.save!

      t = txn!(-285)
      service.auto_match(t)
      expect(t.reload).to have_attributes(status: 'unmatched', matched_journal_entry_id: nil)
      expect(t.review_reason).to include("already in the books as entry #{je.entry_number}", 'already job cost on Garcia set')
      expect(items.count).to eq(1)

      t.match_to_journal_entry!(je)
      expect(t.reload.review_reason).to be_nil
    end

    it 'holds back a charge that pays an open bill on the job' do
      vendor = Contractor.create!(company: company, name: 'NoCo Aggregate', status: 'active')
      bill = company.bills.create!(vendor_id: vendor.id, project: project, bill_date: Date.current, status: 'draft',
                                   bill_line_items_attributes: [{ chart_of_account_id: rental.id, amount: 285, description: 'Gravel' }])
      bill.update!(status: 'pending')

      t = txn!(-285)
      service.auto_match(t)
      expect(t.reload.status).to eq('unmatched')
      expect(t.review_reason).to include("payment of bill #{bill.bill_number}")
      expect(items.count).to eq(1) # the bill's own line, not a second one
    end
  end
end
