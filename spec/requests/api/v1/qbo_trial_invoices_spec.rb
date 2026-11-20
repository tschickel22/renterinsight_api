# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# Going live from a trial: invoices the dealer made in DealerTide during the
# trial, dated on or before the cutover, each answered before posting
# (Accounting::QboMigration::TrialInvoices).
RSpec.describe 'QuickBooks switch: invoices made during the trial', type: :request do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Prairie-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Keeper',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let!(:books) { build_dealer_books(company) }
  let(:base) { '/api/v1/accounting_imports' }

  around { |ex| with_qbo_fixture { ex.run } }
  before do
    stub_claude(company)
    AccountingSettings.for_company(company).update!(auto_post_invoices: true)
  end

  def json = JSON.parse(response.body)

  def post_trial
    post "#{base}/migrations", params: { cutover_date: '2026-09-30', trial: true }, headers: headers, as: :json
    id = json.dig('migration', 'id')
    drive_to_ready(Accounting::QboMigration::Wizard.new(company.accounting_imports.find(id)), books)
    post "#{base}/#{id}/post", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    id
  end

  def finish_uncleared(id)
    wizard = Accounting::QboMigration::Wizard.new(company.accounting_imports.find(id))
    banks = wizard.uncleared_json[:banks].index_by { |b| b[:qbo_account_id] }
    wizard.update_uncleared!([
                               { qbo_account_id: '1', statement_balance: '181300.25', items: banks['1'][:items] },
                               { qbo_account_id: '2', statement_balance: '24310.00', items: [] },
                               { qbo_account_id: '14', statement_balance: '6700.00', items: banks['14'][:items] }
                             ])
  end

  def customer(qbo_id) = company.contacts.find_by!(quickbooks_id: qbo_id)

  def invoice(contact, date, amount, status: 'sent')
    inv = company.invoices.build(contact: contact, location: books[:location], invoice_date: date, due_date: date + 90,
                                 billing_category: 'customer', tax_rate: 0)
    inv.invoice_items.build(description: 'Home sale', quantity: 1, rate: amount, item_type: 'custom', taxable: false, skip_tax: true)
    inv.save!
    unless status == 'draft'
      inv.update!(status: status)
    end
    inv.reload
  end

  def entry_for(inv) = company.journal_entries.where(source_entity_type: 'Invoice', source_entity_id: inv.id).order(:id).first

  it 'asks about each trial invoice, then matches, closes, keeps or cancels it when going live' do
    trial_id = post_trial
    same = invoice(customer('101'), Date.new(2026, 10, 2), 1200)      # QuickBooks 311, 1,200 open
    paid = invoice(customer('104'), Date.new(2026, 10, 5), 500)       # paid in QuickBooks
    kept = invoice(customer('103'), Date.new(2026, 10, 8), 800)       # never entered in QuickBooks
    test = invoice(customer('106'), Date.new(2026, 10, 9), 300)       # a test
    later = invoice(customer('107'), Date.new(2026, 11, 5), 900)      # after the cutover: DealerTide's
    draft = invoice(customer('108'), Date.new(2026, 10, 12), 250, status: 'draft')
    expect([same, paid, kept, test].map { |i| entry_for(i) }).to all(be_present)

    post "#{base}/#{trial_id}/go_live", params: { cutover_date: '2026-10-31' }, headers: headers, as: :json
    live_id = json.dig('migration', 'id')
    expect(json['migration']['steps']['trial_invoices']).to include('done' => false, 'total' => 5, 'answered' => 0)
    expect(json['migration']['blockers']).to include(match(/5 invoices made during the trial/))
    expect(json['migration']['blocker_items'].find { |b| b['message'].include?('made during the trial') }['step']).to eq('trial_invoices')
    finish_uncleared(live_id)

    get "#{base}/#{live_id}/trial_invoices", headers: headers
    rows = json['invoices'].index_by { |r| r['invoice_id'] }
    expect(rows.keys).to match_array([same, paid, kept, test, draft].map(&:id))
    expect(rows.key?(later.id)).to be(false)
    expect(rows[same.id]['suggestion']).to include('answer' => 'same', 'qbo_external_id' => '311')
    expect(json['quickbooks_invoices'].map { |q| q['external_id'] }).to include('311')

    put "#{base}/#{live_id}/trial_invoices", params: { answers: [{ answer: 'accept_suggestions' }] }, headers: headers, as: :json
    expect(json['counts']).to include('answered' => 1)

    # One QuickBooks invoice can only be one of ours.
    put "#{base}/#{live_id}/trial_invoices", params: { answers: [{ invoice_id: paid.id, answer: 'same', qbo_external_id: '311' }] },
                                             headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json['error']).to match(/already picked for invoice #{same.invoice_number}/)

    # A draft can't be settled as QuickBooks': it would post later, dated in QuickBooks' period.
    put "#{base}/#{live_id}/trial_invoices", params: { answers: [{ invoice_id: draft.id, answer: 'paid' }] }, headers: headers, as: :json
    expect(json['invoices'].find { |r| r['invoice_id'] == draft.id }['problems']).to include(match(/Finalize it first/))

    put "#{base}/#{live_id}/trial_invoices", params: { answers: [
      { invoice_id: paid.id, answer: 'paid' }, { invoice_id: kept.id, answer: 'keep' },
      { invoice_id: test.id, answer: 'cancel' }, { invoice_id: draft.id, answer: 'keep' }
    ] }, headers: headers, as: :json
    expect(json['counts']).to include('answered' => 5, 'problems' => 0)

    get "#{base}/#{live_id}/preview", headers: headers
    expect(json['blockers']).to eq([])
    settled = json['settlement']['entries'].map { |e| e['id'] }
    expect(settled).to include(entry_for(same).id, entry_for(paid).id, entry_for(test).id)
    expect(settled).not_to include(entry_for(kept).id)

    post "#{base}/#{live_id}/post", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(json['results']['trial_invoices']).to include('matched' => 1, 'paid' => 1, 'cancelled' => 1, 'kept' => 2)

    # Matched: QuickBooks 311 is this invoice, not a second one.
    expect(same.reload).to have_attributes(quickbooks_id: '311', amount_due: 1200)
    expect(company.invoices.where(quickbooks_id: '311').count).to eq(1)
    expect(entry_for(same).reload.is_void).to be(true)
    # Paid in QuickBooks: closed by an off-books credit, its entry voided.
    expect(paid.reload).to have_attributes(status: 'paid', amount_due: 0)
    expect(entry_for(paid).reload.is_void).to be(true)
    memo = company.credit_memos.find_by(accounting_import_id: live_id)
    expect(memo.reason).to match(/Paid in QuickBooks/)
    expect(company.journal_entries.where(source_entity_type: 'CreditMemo').count).to eq(0)
    # Not in QuickBooks: stays on the books.
    expect(entry_for(kept).reload.is_void).to be(false)
    expect(kept.reload.amount_due).to eq(800)
    # Cancelled.
    expect(test.reload.status).to eq('cancelled')
    # After the cutover: untouched.
    expect(entry_for(later).reload.is_void).to be(false)

    # Rolling back puts each one back.
    post "#{base}/#{live_id}/rollback", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(same.reload.quickbooks_id).to be_nil
    expect(paid.reload).to have_attributes(status: 'sent', amount_due: 500)
    expect(test.reload.status).to eq('sent')
    expect(company.credit_memos.where(accounting_import_id: live_id)).to be_empty
  end

  it 'takes a matched invoice down to what QuickBooks owed when it owed more here' do
    trial_id = post_trial
    mine = invoice(customer('101'), Date.new(2026, 10, 2), 1500)
    post "#{base}/#{trial_id}/go_live", params: { cutover_date: '2026-10-31' }, headers: headers, as: :json
    live_id = json.dig('migration', 'id')
    finish_uncleared(live_id)
    put "#{base}/#{live_id}/trial_invoices", params: { answers: [{ invoice_id: mine.id, answer: 'same', qbo_external_id: '311' }] },
                                             headers: headers, as: :json
    expect(json['invoices'].first['difference']).to eq(300.0)
    get "#{base}/#{live_id}/preview", headers: headers
    post "#{base}/#{live_id}/post", headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(mine.reload).to have_attributes(quickbooks_id: '311', amount_due: 1200)
  end

  it 'has no such step for a first switch or a trial update' do
    trial_id = post_trial
    invoice(customer('101'), Date.new(2026, 10, 2), 1200)
    post "#{base}/#{trial_id}/go_live", params: { cutover_date: '2026-10-31', trial: true }, headers: headers, as: :json
    expect(json['migration']['steps']).not_to have_key('trial_invoices')
    get "#{base}/#{json.dig('migration', 'id')}/trial_invoices", headers: headers
    expect(json).to include('applies' => false, 'invoices' => [])
  end
end
