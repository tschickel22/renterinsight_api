# frozen_string_literal: true

# Where the buyer takes the home (backlog E45): the dealer delivers it to the
# homesite, or the buyer picks it up at the dealer's lot. That decides which
# state taxes the sale: a buyer who takes delivery at an Indiana lot makes it
# an Indiana sale wherever they live.
class AddDeliveryPointToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :delivery_point, :string, null: false, default: 'deliver'
  end
end
