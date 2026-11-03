# frozen_string_literal: true

# The dealer's document fee, on every Deal Sheet and not editable there, and
# retail rounding that can step by $1 or 10 cents. Widening the integer keeps
# every saved step (10, 100, 500, 1000) readable by the code running during the
# release. The table holds one or two rows per dealer, so the rewrite is instant.
class AddDocFeeAndCentsRoundingToDealerCatalogTerms < ActiveRecord::Migration[8.0]
  def up
    add_column :dealer_catalog_terms, :doc_fee, :decimal, precision: 10, scale: 2
    change_column :dealer_catalog_terms, :round_retail_to, :decimal, precision: 10, scale: 2
  end

  def down
    change_column :dealer_catalog_terms, :round_retail_to, :integer, using: 'CEIL(round_retail_to)::integer'
    remove_column :dealer_catalog_terms, :doc_fee
  end
end
