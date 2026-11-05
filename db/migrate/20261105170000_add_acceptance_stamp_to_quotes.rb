# frozen_string_literal: true

# Who accepted a quote and from where, shown to the buyer and the dealer.
class AddAcceptanceStampToQuotes < ActiveRecord::Migration[8.0]
  def change
    add_column :quotes, :accepted_ip, :string
    # public_link or portal: the buyer did it. dealer: someone at the dealership marked it.
    add_column :quotes, :accepted_via, :string
    add_column :quotes, :accepted_by_name, :string
  end
end
