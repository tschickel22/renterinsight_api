# frozen_string_literal: true

class AddDealIdToServiceTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :service_tickets, :deal_id, :bigint
    add_index :service_tickets, :deal_id
    add_foreign_key :service_tickets, :deals, on_delete: :nullify
  end
end
