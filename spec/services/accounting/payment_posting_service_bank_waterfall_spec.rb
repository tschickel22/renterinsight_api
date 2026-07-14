# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounting::PaymentPostingService, type: :service do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'B', last_name: 'One', email: "b-#{SecureRandom.hex(4)}@example.com") }

  # Seed real bank accounts + linked CoA rows so the waterfall has actual
  # things to pick from at each rung.
  let(:coa_payment_bank)  { company.chart_of_accounts.find_or_create_by!(account_number: 'BANK-P') { |a| a.name = 'Payment Bank'; a.account_type = 'asset'; a.normal_balance = 'debit'; a.sub_type = 'bank' } }
  let(:coa_location_bank) { company.chart_of_accounts.find_or_create_by!(account_number: 'BANK-L') { |a| a.name = 'Loc Bank'; a.account_type = 'asset'; a.normal_balance = 'debit'; a.sub_type = 'bank' } }
  let(:coa_default_bank)  { company.chart_of_accounts.find_or_create_by!(account_number: 'BANK-D') { |a| a.name = 'Default Bank'; a.account_type = 'asset'; a.normal_balance = 'debit'; a.sub_type = 'bank' } }

  # Use sync_only + credit_card variations to skip the routing/account
  # detail validations that don't matter for waterfall behavior.
  def make_bank(purpose:, coa:, location: nil)
    BankAccount.create!(
      company: company, location: location, chart_of_account: coa,
      account_purpose: purpose, account_type: 'credit_card', bank_name: "BA-#{coa.account_number}",
      is_active: true
    )
  end

  # bank_accounts has a unique (location, purpose, is_deleted) index, so use
  # different purposes when we need multiple banks at one location.
  let(:other_location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:payment_bank)  { make_bank(purpose: 'deposit',   coa: coa_payment_bank,  location: location) }
  let(:location_bank) { make_bank(purpose: 'operating', coa: coa_location_bank, location: location) }
  let(:default_bank)  { make_bank(purpose: 'operating', coa: coa_default_bank,  location: other_location) }

  let(:settings) { AccountingSettings.find_or_create_by!(company: company) }

  def build_payment(bank_account: nil)
    company.payments.create!(
      amount: 100, payment_type: 'one_time', status: 'completed',
      payer: contact, payment_date: Date.current, gateway_name: 'manual',
      location: location, bank_account: bank_account
    )
  end

  describe '#resolve_bank_account waterfall' do
    it 'prefers the payment-level bank_account when set' do
      payment_bank; location_bank; default_bank
      settings.update!(default_bank_account_id: default_bank.id)
      payment = build_payment(bank_account: payment_bank)

      resolved = described_class.new(payment).send(:resolve_bank_account, settings.reload)
      expect(resolved).to eq(coa_payment_bank)
    end

    it 'falls back to the location operating_bank_account when payment has none' do
      location_bank; default_bank
      settings.update!(default_bank_account_id: default_bank.id)
      payment = build_payment(bank_account: nil)

      resolved = described_class.new(payment).send(:resolve_bank_account, settings.reload)
      expect(resolved).to eq(coa_location_bank)
    end

    it 'falls back to the company default when neither payment nor location has one' do
      # Explicitly no location banks
      default_bank
      settings.update!(default_bank_account_id: default_bank.id)
      payment = company.payments.create!(
        amount: 50, payment_type: 'one_time', status: 'completed',
        payer: contact, payment_date: Date.current, gateway_name: 'manual'
        # no location, no bank_account
      )

      resolved = described_class.new(payment).send(:resolve_bank_account, settings.reload)
      expect(resolved).to eq(coa_default_bank)
    end

    it 'returns nil when nothing is configured — caller logs and skips posting' do
      payment = company.payments.create!(
        amount: 50, payment_type: 'one_time', status: 'completed',
        payer: contact, payment_date: Date.current, gateway_name: 'manual'
      )
      resolved = described_class.new(payment).send(:resolve_bank_account, settings.reload)
      expect(resolved).to be_nil
    end
  end
end
