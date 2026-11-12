# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# A QuickBooks bank or card can be "part of" another: employee cards that the
# bank reports on the company card's one statement. It has no bank account of
# its own; its balance goes to the other one's account, and its uncleared
# items and balance tie out on that statement. The fixture company has no
# sub-card, so Wells Fargo Payroll (2) plays the part, inside Chase (1).
RSpec.describe 'QuickBooks switch: an account that is part of another' do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Prairie-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Keeper',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let!(:books) { build_dealer_books(company) }

  around { |ex| with_qbo_fixture { ex.run } }
  before { stub_claude(company) }

  def start
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    Accounting::QboMigration::Wizard.new(import)
  end

  def reload(w) = Accounting::QboMigration::Wizard.new(w.import.reload)

  def ready_with_payroll_inside_chase
    wizard = start
    Accounting::QboMigration::AccountSuggester.new(wizard).run!
    wizard.update_accounts!([], confirm_suggested: true)
    wizard.update_banks!([
                           { qbo_account_id: '1', bank_account_id: books[:banks][:chase].id },
                           { qbo_account_id: '2', part_of: '1' },
                           { qbo_account_id: '14', bank_account_id: books[:banks][:amex].id }
                         ])
    pending = wizard.account_rows.select { |r| !r['confirmed'] && r['choice'].present? }
                    .map { |r| { qbo_account_id: r['qbo_account_id'], confirmed: true } }
    wizard.update_accounts!(pending)
    wizard
  end

  it 'ties the part out on the other one\'s statement and posts one reconciliation for both' do
    wizard = ready_with_payroll_inside_chase
    rows = wizard.account_rows.index_by { |r| r['qbo_account_id'] }
    expect(rows['2']).to include('bank_match' => true, 'confirmed' => true, 'choice' => { 'action' => 'follow', 'qbo_account_id' => '1' })

    banks = wizard.uncleared_json[:banks].index_by { |b| b[:qbo_account_id] }
    expect(banks.keys).to contain_exactly('1', '14')
    chase = banks['1']
    expect(chase[:includes]).to eq(['Wells Fargo Payroll'])
    expect(chase[:balance_at_cutover]).to eq((BigDecimal(rows['1']['balance_at_cutover']) + BigDecimal(rows['2']['balance_at_cutover'])).round(2).to_f)

    # The two statements the fixture ties to, as one.
    wizard.update_uncleared!([
                               { qbo_account_id: '1', statement_balance: '205610.25', items: chase[:items] },
                               { qbo_account_id: '14', statement_balance: '6700.00', items: banks['14'][:items] }
                             ])
    wizard = reload(wizard)
    expect(wizard.uncleared_difference(wizard.bank_rows.find { |b| b['qbo_account_id'] == '1' })).to eq(0)

    preview = wizard.preview_json
    expect(preview[:blockers]).to eq([])
    expect(preview[:totals][:debit]).to eq(preview[:totals][:credit])

    Accounting::QboMigration::Poster.new(wizard, user).post!
    expect(company.bank_reconciliations.where(accounting_import_id: wizard.import.id).count).to eq(2)
    gl = books[:banks][:chase].reload.chart_of_account
    net = JournalEntryLine.joins(:journal_entry).merge(JournalEntry.in_ledger).where(chart_of_account_id: gl.id).sum('debit_amount - credit_amount')
    expect(net).to eq(BigDecimal(rows['1']['tb_balance']) + BigDecimal(rows['2']['tb_balance']))
  end

  it 'removes the empty bank account the switch made for it, and moves items back when it stands alone again' do
    wizard = start
    wizard.create_bank_accounts!
    wizard = reload(wizard)
    made = wizard.bank_rows.find { |b| b['qbo_account_id'] == '1' }.dig('match', 'bank_account_id')
    made_account = company.bank_accounts.find(made)
    own_items = wizard.config.dig('uncleared', '1', 'items').size
    expect(own_items).to be_positive

    wizard.update_banks!([{ qbo_account_id: '1', part_of: '2' }])
    wizard = reload(wizard)
    expect(made_account.reload.is_deleted).to be(true)
    expect(wizard.config['uncleared']).not_to have_key('1')
    expect(wizard.config.dig('uncleared', '2', 'items').count { |i| i['from_account'] == '1' }).to eq(own_items)
    expect(wizard.uncleared_json[:banks].find { |b| b[:qbo_account_id] == '2' }[:items].map { |i| i[:from_account] }.compact.uniq)
      .to eq(['Chase Operating Checking'])

    wizard.update_banks!([{ qbo_account_id: '1', bank_account_id: books[:banks][:chase].id }])
    wizard = reload(wizard)
    expect(wizard.config.dig('uncleared', '1', 'items').size).to eq(own_items)
    expect(wizard.config.dig('uncleared', '2', 'items').count { |i| i['from_account'] }).to eq(0)
    expect(wizard.account_rows.find { |r| r['qbo_account_id'] == '1' }.dig('choice', 'action')).not_to eq('follow')
  end

  it 'refuses a card inside a bank, an account inside itself, and a part of a part' do
    wizard = start
    expect { wizard.update_banks!([{ qbo_account_id: '14', part_of: '1' }]) }.to raise_error(Accounting::QboMigration::Error, /only be part of another card/)
    expect { wizard.update_banks!([{ qbo_account_id: '1', part_of: '1' }]) }.to raise_error(Accounting::QboMigration::Error, /pick another/)
    wizard.update_banks!([{ qbo_account_id: '2', part_of: '1' }])
    wizard = reload(wizard)
    expect { wizard.update_banks!([{ qbo_account_id: '1', part_of: '2' }]) }.to raise_error(Accounting::QboMigration::Error, /not part of a part/)
    expect(wizard.bank_match_problems(wizard.bank_rows.find { |b| b['qbo_account_id'] == '2' }).join).to include('not matched')
  end

  it 'finds the card an employee card sits under from its QuickBooks name' do
    wizard = start
    amex = wizard.account_rows.find { |r| r['qbo_account_id'] == '14' }
    child = wizard.bank_rows.find { |b| b['qbo_account_id'] == '2' }
    wizard.config['accounts'].find { |r| r['qbo_account_id'] == '2' }['qbo_name'] = "#{amex['qbo_name']}:Justin 1740"
    expect(wizard.qbo_parent_bank_id(child)).to eq('14')
  end
end
