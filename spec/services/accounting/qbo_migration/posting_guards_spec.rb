# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# From the 2026-10-04 sandbox post: 36,642.84 of income was mapped to
# 1110 Customer Receivables, a matched bank was linked to the same
# receivables account, and 40 open invoices already in DealerTide from an
# earlier QuickBooks sync were skipped. Each now stops the post.
RSpec.describe 'QuickBooks switch posting guards' do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Guards-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "g-#{SecureRandom.hex(4)}@example.com", first_name: 'G', last_name: 'D',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let!(:books) { build_dealer_books(company) }

  around { |ex| with_qbo_fixture { ex.run } }
  before { stub_claude(company) }

  def ready
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    drive_to_ready(Accounting::QboMigration::Wizard.new(import), books)
  end

  it 'is ready before any of this' do
    expect(ready.preview_json[:blockers]).to eq([])
  end

  it 'stops an income account with a balance going to an asset account' do
    wizard = ready
    row = wizard.account_rows.find { |r| r['dt_account_type'] == 'revenue' && Accounting::QboMigration::Wizard.d(r['tb_balance']).nonzero? }
    wizard.update_accounts!([{ qbo_account_id: row['qbo_account_id'], action: 'map',
                               chart_of_account_id: books[:chart]['1110'].id, confirmed: true }])

    blockers = Accounting::QboMigration::Wizard.new(wizard.import.reload).preview_json[:blockers]
    expect(blockers.join).to include("#{row['qbo_name']}: it is an income account in QuickBooks but goes to 1110")
    public = Accounting::QboMigration::Wizard.new(wizard.import).accounts_json.find { |r| r[:qbo_account_id] == row['qbo_account_id'] }
    expect(public[:type_problem]).to include('Choose an income account')
    expect(Accounting::QboMigration::Wizard.new(wizard.import).needs_attention?(wizard.account_rows.find { |r| r['qbo_account_id'] == row['qbo_account_id'] })).to be(true)
  end

  it 'stops a bank whose DealerTide account is not a bank account' do
    wizard = ready
    books[:banks][:chase].update!(chart_of_account: books[:chart]['1110'])

    blockers = Accounting::QboMigration::Wizard.new(wizard.import.reload).preview_json[:blockers]
    expect(blockers.join).to include('an accounts receivable account, not a bank account')
  end

  it 'stops open invoices already in DealerTide with another balance, and lets matching ones through' do
    wizard = ready
    open = wizard.config['open_invoices'].first(2)
    contact = company.contacts.create!(first_name: 'Synced', last_name: 'Earlier')
    differing, matching = open.map do |inv|
      company.invoices.create!(invoice_number: "SYNC-#{inv['external_id']}", invoice_date: Date.new(2026, 8, 1), status: 'sent',
                               contact_id: contact.id, location_id: wizard.default_location_id, quickbooks_id: inv['external_id'])
    end
    matching.invoice_items.create!(description: 'Synced', quantity: 1, rate: open.last['balance'].to_d, item_type: 'custom')
    matching.reload.save!

    blockers = Accounting::QboMigration::Wizard.new(wizard.import.reload).preview_json[:blockers]
    expect(blockers.join).to include('1 open QuickBooks invoice is already in DealerTide')
    expect(blockers.join).to include(differing.invoice_number)
    expect(blockers.join).not_to include(matching.invoice_number)
  end

  it 'says which step fixes each blocker' do
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    wizard = Accounting::QboMigration::Wizard.new(import)
    wizard.update_banks!([{ qbo_account_id: '1', bank_account_id: books[:banks][:chase].id, closed: false }])

    items = Accounting::QboMigration::Wizard.new(import.reload).preview_json[:blocker_items]
    by_step = items.group_by { |i| i[:step] }
    expect(by_step['accounts'].map { |i| i[:message] }.join).to include('not confirmed yet')
    expect(by_step['banks'].map { |i| i[:message] }.join).to include('is not matched to a bank account')
    expect(by_step['uncleared'].map { |i| i[:message] }.join).to include('enter the bank statement balance at cutover')
    expect(items.map { |i| i[:message] }).to eq(Accounting::QboMigration::Wizard.new(import.reload).blockers(include_preview: false))
  end
end
