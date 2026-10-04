# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# Found on the 2026-10-04 sandbox run: open invoices came to 785.65 more than
# receivables, because QuickBooks credit memos and unapplied payments lower AR
# without being open invoices; and the post stopped on "Invoice number has
# already been taken", because QuickBooks lets two invoices share a number.
RSpec.describe 'QuickBooks switch: customer credits and invoice numbers' do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Credits-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let!(:books) { build_dealer_books(company) }

  around { |ex| with_qbo_fixture { ex.run } }
  before { stub_claude(company) }

  let(:credits) do
    [
      { external_id: '601', kind: 'credit_memo', doc_number: 'CM-12', date: Date.new(2026, 9, 20),
        customer_external_id: '101', customer_name: 'Jake and Maria Thompson', total: 250.to_d, balance: 250.to_d },
      { external_id: '701', kind: 'unapplied_payment', doc_number: '5521', date: Date.new(2026, 9, 26),
        customer_external_id: '120', customer_name: 'Walk-in Buyer', total: 75.to_d, balance: 75.to_d }
    ]
  end

  def wizard_with_credits
    allow_any_instance_of(Accounting::Adapters::QuickbooksOnlineAdapter)
      .to receive(:fetch_open_customer_credits).and_return(credits)
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    drive_to_ready(Accounting::QboMigration::Wizard.new(import), books)
  end

  it 'nets customer credits against open invoices in the preview' do
    preview = wizard_with_credits.preview_json
    expect(preview[:open_invoices]).to include(invoices_total: 52_290.40, customer_credits_total: 325.0,
                                               customer_credits_count: 2, total: 51_965.40,
                                               unapplied_customer_credits: 75.0, difference: -325.0)
    expect(preview[:differences].join).to include('75.00 of customer credits has no open invoice')
  end

  it "applies a credit to the customer's open invoice and carries a leftover as a credit memo" do
    wizard = wizard_with_credits
    Accounting::QboMigration::Poster.new(wizard, user).post!

    thompson = company.invoices.find_by!(quickbooks_id: '301')
    expect(thompson.total.to_d).to eq(4600.to_d)
    expect(thompson.notes).to include('credit memo CM-12 250.00')

    memo = company.credit_memos.find_by!(quickbooks_id: 'Payment:701')
    expect(memo).to have_attributes(status: 'issued', accounting_import_id: wizard.import.id)
    expect(memo.total.to_d).to eq(75.to_d)
    expect(memo.amount_remaining.to_d).to eq(75.to_d)
    expect(memo.reason).to include('unapplied payment 5521')

    Accounting::QboMigration::Rollback.new(Accounting::QboMigration::Wizard.new(wizard.import.reload)).run!(user)
    expect(company.credit_memos.where(accounting_import_id: wizard.import.id)).to be_empty
  end

  it 'gives every carried invoice a number of its own' do
    allow_any_instance_of(Accounting::Adapters::QuickbooksOnlineAdapter).to receive(:fetch_open_customer_credits).and_return([])
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    wizard = Accounting::QboMigration::Wizard.new(import)
    # QuickBooks allows duplicates, and the dealer already has 1043 and QB-1043.
    wizard.config['open_invoices'].each { |i| i['invoice_number'] = '1043' }
    wizard.save!
    contact = company.contacts.create!(first_name: 'Existing', last_name: 'Buyer')
    %w[1043 QB-1043].each do |n|
      company.invoices.create!(invoice_number: n, invoice_date: Date.new(2026, 9, 1), status: 'draft',
                               contact_id: contact.id, location_id: wizard.default_location_id)
    end

    drive_to_ready(wizard, books)
    Accounting::QboMigration::Poster.new(wizard, user).post!

    numbers = company.invoices.where(accounting_import_id: import.id).pluck(:invoice_number)
    expect(numbers.size).to eq(10)
    expect(numbers.uniq.size).to eq(10)
    expect(numbers).to include('QB-1043-2')
    expect(numbers).not_to include('1043', 'QB-1043')
  end

  it 'reads credit memos with credit left and payments with an unapplied amount from QuickBooks' do
    client = Accounting::QboMigration::FixtureClient.new(overrides: {
      'CreditMemo' => { 'QueryResponse' => { 'CreditMemo' => [
        { 'Id' => '601', 'DocNumber' => 'CM-12', 'TxnDate' => '2026-09-20', 'TotalAmt' => 250, 'RemainingCredit' => 250,
          'CustomerRef' => { 'value' => '101', 'name' => 'Jake and Maria Thompson' } },
        { 'Id' => '602', 'DocNumber' => 'CM-13', 'TxnDate' => '2026-09-21', 'TotalAmt' => 90, 'RemainingCredit' => 0,
          'CustomerRef' => { 'value' => '102' } },
        { 'Id' => '603', 'DocNumber' => 'CM-14', 'TxnDate' => '2026-10-03', 'TotalAmt' => 40, 'RemainingCredit' => 40,
          'CustomerRef' => { 'value' => '103' } }
      ] } },
      'Payment' => { 'QueryResponse' => { 'Payment' => [
        { 'Id' => '701', 'PaymentRefNum' => '5521', 'TxnDate' => '2026-09-26', 'TotalAmt' => 75, 'UnappliedAmt' => 75,
          'CustomerRef' => { 'value' => '109', 'name' => 'Hillside MHC' } },
        { 'Id' => '702', 'TxnDate' => '2026-09-27', 'TotalAmt' => 100, 'UnappliedAmt' => 0, 'CustomerRef' => { 'value' => '104' } }
      ] } }
    })
    adapter = Accounting::Adapters::QuickbooksOnlineAdapter.new(company, nil, {}, client: client)

    found = adapter.fetch_open_customer_credits(QboMigrationHelpers::CUTOVER)
    expect(found.map { |c| [c[:kind], c[:external_id], c[:balance].to_f] })
      .to contain_exactly(['credit_memo', '601', 250.0], ['unapplied_payment', '701', 75.0])
  end
end
