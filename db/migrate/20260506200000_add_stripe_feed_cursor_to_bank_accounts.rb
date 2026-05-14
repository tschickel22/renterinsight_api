# frozen_string_literal: true

class AddStripeFeedCursorToBankAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_accounts, :stripe_last_cursor, :string unless column_exists?(:bank_accounts, :stripe_last_cursor)
    add_column :bank_accounts, :stripe_error_message, :text unless column_exists?(:bank_accounts, :stripe_error_message)
  end
end
