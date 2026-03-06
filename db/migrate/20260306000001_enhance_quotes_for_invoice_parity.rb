# frozen_string_literal: true

class EnhanceQuotesForInvoiceParity < ActiveRecord::Migration[8.0]
  def change
    # Add deal linking (same as invoices)
    add_column :quotes, :deal_id, :integer, null: true unless column_exists?(:quotes, :deal_id)

    # Add dedicated terms column (move from custom_fields)
    add_column :quotes, :terms, :text, null: true unless column_exists?(:quotes, :terms)

    # Add invoice-level default tax rate
    add_column :quotes, :tax_rate, :decimal, precision: 5, scale: 2, default: 0.0 unless column_exists?(:quotes, :tax_rate)

    # Add sales rep tracking
    add_column :quotes, :sales_rep_id, :integer, null: true unless column_exists?(:quotes, :sales_rep_id)

    # Add pricing display mode (detailed vs bundled)
    add_column :quotes, :pricing_display, :string, default: 'detailed' unless column_exists?(:quotes, :pricing_display)

    # Add draw schedule (same JSONB pattern as invoices)
    add_column :quotes, :draw_schedule, :jsonb, default: {} unless column_exists?(:quotes, :draw_schedule)

    # Indexes
    add_index :quotes, :deal_id, name: 'index_quotes_on_deal_id' unless index_exists?(:quotes, :deal_id)
    add_index :quotes, :sales_rep_id, name: 'index_quotes_on_sales_rep_id' unless index_exists?(:quotes, :sales_rep_id)
  end
end
