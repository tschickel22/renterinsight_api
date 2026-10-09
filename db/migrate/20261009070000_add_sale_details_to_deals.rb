# frozen_string_literal: true

# The contract's sale details on the Deal Sheet (backlog E46): the site, the
# contingency, the financing or cash addendum, the unit identity. Fields the
# deal already holds (buyers, delivery address, payment type, lender) stay
# where they are.
class AddSaleDetailsToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :sale_details, :jsonb, null: false, default: {}
  end
end
