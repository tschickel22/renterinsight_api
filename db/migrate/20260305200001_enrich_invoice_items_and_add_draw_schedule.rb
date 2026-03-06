# Phase 1C: Enrich invoice_items with category, cost, taxable, tax_rate, notes
# Phase 2B prep: Add draw_schedule JSONB to invoices
class EnrichInvoiceItemsAndAddDrawSchedule < ActiveRecord::Migration[8.0]
  def change
    # Invoice Items enrichment - richer line items matching deal product pattern
    add_column :invoice_items, :category, :string unless column_exists?(:invoice_items, :category)
    add_column :invoice_items, :cost, :decimal, precision: 10, scale: 2, default: 0.0 unless column_exists?(:invoice_items, :cost)
    add_column :invoice_items, :taxable, :boolean, default: false unless column_exists?(:invoice_items, :taxable)
    add_column :invoice_items, :tax_rate, :decimal, precision: 5, scale: 2, default: 0.0 unless column_exists?(:invoice_items, :tax_rate)
    add_column :invoice_items, :notes, :text unless column_exists?(:invoice_items, :notes)

    # Draw schedule on invoice (JSONB) - for lender disbursement schedules
    add_column :invoices, :draw_schedule, :jsonb, default: {} unless column_exists?(:invoices, :draw_schedule)
  end
end
