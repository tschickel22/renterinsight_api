class AddDepositAmountToLeadContactAccount < ActiveRecord::Migration[8.0]
  def change
    add_column :leads,    :deposit_amount, :decimal, precision: 15, scale: 2
    add_column :contacts, :deposit_amount, :decimal, precision: 15, scale: 2
    add_column :accounts, :deposit_amount, :decimal, precision: 15, scale: 2
  end
end
