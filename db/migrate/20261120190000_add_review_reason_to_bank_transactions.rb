# frozen_string_literal: true

# Why a bank rule filled in a line but did not post it (E109): the money looks
# already in the books, or looks like the payment of an open bill. A person
# confirms or matches it instead, so the job is not charged twice.
class AddReviewReasonToBankTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_transactions, :review_reason, :text
  end
end
