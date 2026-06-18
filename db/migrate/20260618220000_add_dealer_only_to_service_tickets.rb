# frozen_string_literal: true

# Adds a dealer-only flag to service tickets. Dealer-only tickets are internal
# (typically pre-sale work on a home, e.g. damage found on factory arrival) and
# are never surfaced in the customer portal until the dealer explicitly opts in.
class AddDealerOnlyToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :service_tickets, :dealer_only, :boolean, default: false, null: false
    add_index :service_tickets, :dealer_only
  end
end
