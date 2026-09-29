# frozen_string_literal: true

require 'rails_helper'

# The processor keeps its fee out of each deposit. When the company absorbs
# the fee the bank receives the payment less the fee, and the fee is an
# expense; when the customer pays it, the dealer receives the full payment.
RSpec.describe Accounting::PaymentPostingService, 'processing fees' do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'B', last_name: 'One', email: "b-#{SecureRandom.hex(4)}@example.com") }
  let(:settings) { AccountingSettings.find_or_create_by!(company: company) }
  let(:bank_coa) do
    company.chart_of_accounts.find_or_create_by!(account_number: 'BANK-F') do |a|
      a.name = 'Fee Test Bank'; a.account_type = 'asset'; a.normal_balance = 'debit'; a.sub_type = 'bank'
    end
  end
  let(:bank) do
    BankAccount.create!(company: company, location: location, chart_of_account: bank_coa, account_purpose: 'deposit',
                        account_type: 'credit_card', bank_name: 'Fee Test', is_active: true)
  end

  before do
    skip 'seed has no AR account' unless settings.default_ar_account
    settings.update!(auto_post_payments: true)
  end

  def pay(fee:, responsibility:)
    company.payments.create!(
      amount: 100, payment_type: 'one_time', status: 'completed', payer: contact,
      payment_date: Date.current, gateway_name: 'manual', location: location, bank_account: bank,
      processing_fee: fee, fee_responsibility: responsibility
    )
  end

  # A completed payment posts itself on save; post! covers the case where it
  # didn't, and is a no-op when it already has.
  def posted_entry(payment)
    described_class.new(payment).post!
    company.journal_entries.find_by(source_entity: payment)
  end

  def lines_of(je) = je.journal_entry_lines.map { |l| [l.chart_of_account.name, l.debit_amount, l.credit_amount] }

  it 'posts the net deposit to the bank and the fee to Merchant Processing Fees when the company pays it' do
    je = posted_entry(pay(fee: BigDecimal('3.20'), responsibility: 'company'))

    expect(lines_of(je)).to contain_exactly(
      ['Fee Test Bank', BigDecimal('96.80'), 0],
      ['Merchant Processing Fees', BigDecimal('3.20'), 0],
      [settings.default_ar_account.name, 0, BigDecimal('100')]
    )
  end

  it 'posts the full payment to the bank when the customer pays the fee' do
    je = posted_entry(pay(fee: BigDecimal('3.20'), responsibility: 'customer'))

    expect(lines_of(je)).to contain_exactly(
      ['Fee Test Bank', BigDecimal('100'), 0],
      [settings.default_ar_account.name, 0, BigDecimal('100')]
    )
  end
end
