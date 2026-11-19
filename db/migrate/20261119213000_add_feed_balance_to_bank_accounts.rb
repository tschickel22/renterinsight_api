# frozen_string_literal: true

# The balance the bank reports through its feed, kept apart from
# current_balance (typed by hand on banks without a feed). Statement terms:
# money held, or for a card what is owed.
class AddFeedBalanceToBankAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_accounts, :feed_balance, :decimal, precision: 15, scale: 2
    add_column :bank_accounts, :feed_balance_as_of, :datetime
    add_column :bank_accounts, :feed_balance_requested_at, :datetime
  end
end
