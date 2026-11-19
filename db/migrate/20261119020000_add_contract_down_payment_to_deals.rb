# frozen_string_literal: true

# The down payment written on the contract. deals.down_payment is the deposit
# (the UI and reports call it Deposit) and does not print on the Form 500.
class AddContractDownPaymentToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :contract_down_payment, :decimal, precision: 15, scale: 2
  end
end
