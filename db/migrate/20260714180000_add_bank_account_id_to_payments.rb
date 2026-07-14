# frozen_string_literal: true

# Enterprise bank waterfall for payments: payment.bank_account_id is the top
# rung (per-payment override), then payment.location.operating_bank_account
# (per-location default via the existing bank_accounts.location_id scoping),
# then accounting_settings.default_bank_account (per-company default).
class AddBankAccountIdToPayments < ActiveRecord::Migration[8.0]
  def change
    add_reference :payments, :bank_account, foreign_key: true, index: true
  end
end
