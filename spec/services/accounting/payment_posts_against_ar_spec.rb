# frozen_string_literal: true

require 'rails_helper'

# Invoice and payment posting on for everyone (2026-10-16): a payment credits
# AR, so it posts only against an invoice that is in AR, posting an older one
# first. Loan installments are not sales and stay off the books.
RSpec.describe Accounting::PaymentPostingService, 'only against AR' do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'B', last_name: 'One', email: "b-#{SecureRandom.hex(4)}@example.com") }
  let(:settings) { AccountingSettings.find_or_create_by!(company: company) }
  let(:bank_coa) do
    company.chart_of_accounts.find_or_create_by!(account_number: 'BANK-AR') do |a|
      a.name = 'AR Test Bank'; a.account_type = 'asset'; a.normal_balance = 'debit'; a.sub_type = 'bank'
    end
  end
  let(:bank) do
    BankAccount.create!(company: company, location: location, chart_of_account: bank_coa, account_purpose: 'sync_only',
                        account_type: 'checking', bank_name: 'AR Test', is_active: true)
  end

  before { skip 'seed has no AR account' unless settings.default_ar_account }

  def invoice!(loan: nil)
    inv = company.invoices.create!(location: location, contact: contact, invoice_number: "INV-A-#{SecureRandom.hex(3)}",
                                   invoice_date: Date.current, due_date: Date.current, status: 'draft', loan_id: loan)
    inv.invoice_items.create!(description: 'Service', quantity: 1, rate: 100, amount: 100)
    inv
  end

  def pay(payable)
    company.payments.create!(payable: payable, amount: 100, payment_type: 'one_time', status: 'completed', payer: contact,
                             payment_date: Date.current, gateway_name: 'manual', location: location, bank_account: bank)
  end

  def posted?(record) = company.journal_entries.where(source_entity: record, is_void: false).exists?

  it 'posts an invoice sent before posting was on when a payment on it arrives, then the payment' do
    settings.update!(auto_post_invoices: false, auto_post_payments: false)
    invoice = invoice!
    invoice.update!(status: 'sent')
    expect(posted?(invoice)).to be(false)

    settings.update!(auto_post_invoices: true, auto_post_payments: true)
    payment = pay(invoice)
    expect(posted?(invoice)).to be(true)
    expect(posted?(payment)).to be(true)
  end

  it 'keeps loan installments and their payments off the books' do
    settings.update!(auto_post_invoices: true, auto_post_payments: true)
    installment = invoice!(loan: 0)
    installment.update_column(:loan_id, 123_456)
    installment.update!(status: 'sent')
    expect(posted?(installment)).to be(false)

    payment = pay(installment)
    expect(posted?(payment)).to be(false)
  end

  it 'does not post a payment that pays no invoice' do
    settings.update!(auto_post_payments: true)
    payment = company.payments.create!(amount: 100, payment_type: 'one_time', status: 'completed', payer: contact,
                                       payment_date: Date.current, gateway_name: 'manual', location: location, bank_account: bank)
    expect(posted?(payment)).to be(false)
  end
end
