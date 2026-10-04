# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# Found on the 2026-10-04 sandbox run: 10 of 90 accounts came back with no
# suggestion (skipped by the AI, or offered an account the checks reject),
# including a 36,642.84 income account, and a hand-typed detail type that
# does not exist failed on save.
RSpec.describe Accounting::QboMigration::AccountSuggester do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Gaps-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "g-#{SecureRandom.hex(4)}@example.com", first_name: 'G', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let!(:books) { build_dealer_books(company) }

  around { |ex| with_qbo_fixture { ex.run } }

  def wizard
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    Accounting::QboMigration::Wizard.new(import)
  end

  # Answers like fake_claude_answer, minus the rows named in skip; records
  # which rows each call was asked about.
  def stub_claude_skipping(skip_first:, skip_retry:)
    full = fake_claude_answer(company)
    calls = []
    allow_any_instance_of(described_class).to receive(:request_claude) do |_i, system, text|
      calls << JSON.parse(text[text.index('{')..])['quickbooks_accounts'].map { |a| a['qbo_account_id'] }
      skip = calls.size == 1 ? skip_first : skip_retry
      answer = JSON.parse(full.call(system, text))
      answer['suggestions'].reject! { |s| skip.include?(s['qbo_account_id'].to_s) }
      answer.to_json
    end
    calls
  end

  it 'asks again for rows the first answer skipped' do
    w = wizard
    skipped = w.account_rows.reject { |r| r.dig('suggestion', 'source') == 'exact' }.first(2).map { |r| r['qbo_account_id'] }
    calls = stub_claude_skipping(skip_first: skipped, skip_retry: [])

    described_class.new(w).run!

    expect(calls.size).to eq(2)
    expect(calls.last).to match_array(skipped)
    rows = w.account_rows.index_by { |r| r['qbo_account_id'] }
    skipped.each { |id| expect(rows[id]['suggestion']).to include('source' => 'ai') }
    expect(w.account_rows.count { |r| r['suggestion'].nil? }).to eq(0)
  end

  it 'falls back to a new account with the QuickBooks name when the retry skips them too' do
    w = wizard
    row = w.account_rows.find { |r| r['dt_account_type'] == 'revenue' && r.dig('suggestion', 'source') != 'exact' }
    stub_claude_skipping(skip_first: [row['qbo_account_id']], skip_retry: [row['qbo_account_id']])

    described_class.new(w).run!

    sug = w.account_rows.find { |r| r['qbo_account_id'] == row['qbo_account_id'] }['suggestion']
    expect(sug).to include('action' => 'create', 'confidence' => 'low')
    expect(sug['new_account']).to include('name' => row['qbo_name'], 'account_type' => 'revenue')
    expect(sug['new_account']['number']).to be_present
    expect(company.chart_of_accounts.exists?(account_number: sug['new_account']['number'])).to be(false)
    expect(ChartOfAccount::SUB_TYPES_BY_TYPE['revenue']).to include(sug['new_account']['sub_type']) if sug['new_account']['sub_type']

    # Low confidence: Confirm all suggested leaves it for a person.
    w.update_accounts!([], confirm_suggested: true)
    expect(w.account_rows.find { |r| r['qbo_account_id'] == row['qbo_account_id'] }['confirmed']).to be(false)
  end

  it 'keeps only a detail type that fits the account type' do
    w = wizard
    row = w.account_rows.find { |r| r['dt_account_type'] == 'revenue' }
    entry = ->(sub) { [{ qbo_account_id: row['qbo_account_id'], action: 'create', confirmed: true,
                         new_account: { number: '4777', name: 'Billable Expense Income', account_type: 'revenue', sub_type: sub } }] }

    expect { w.update_accounts!(entry.call('Service Fee income')) }.to raise_error(Accounting::QboMigration::Error, /not a detail type for revenue/)
    expect { w.update_accounts!(entry.call('operating_expense')) }.to raise_error(Accounting::QboMigration::Error, /not a detail type for revenue/)
    w.update_accounts!(entry.call('service_revenue'))
    expect(w.account_rows.find { |r| r['qbo_account_id'] == row['qbo_account_id'] }.dig('choice', 'new_account', 'sub_type')).to eq('service_revenue')
  end
end
