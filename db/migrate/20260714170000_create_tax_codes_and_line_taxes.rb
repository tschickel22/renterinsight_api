# frozen_string_literal: true

# TaxCode + InvoiceItemTax replace the ambiguous single tax_rate on invoices.
# Each taxable line item gets one snapshot row per applicable tax code (an
# invoice_item_taxes row with a computed amount) so that compound tax, split
# jurisdictions, and QB TaxCode ref mapping all become expressible.
#
# Also adds tax-exempt flags on contacts and a per-line skip_tax override so
# enterprise dealers can suppress tax where required (exempt buyers, resale
# certificates, etc.).
class CreateTaxCodesAndLineTaxes < ActiveRecord::Migration[8.0]
  def change
    create_table :tax_codes do |t|
      t.references :company, null: false, foreign_key: true
      t.string     :name, null: false
      t.decimal    :rate, precision: 8, scale: 5, null: false, default: 0
      t.boolean    :is_compound, null: false, default: false
      t.string     :tax_authority           # 'state' | 'county' | 'city' | 'special' | anything
      t.references :chart_of_account,       # which liability account this tax posts to
                   foreign_key: true
      t.string     :qbo_tax_code_id         # QB TaxCode ref for outbound sync
      t.boolean    :is_active, null: false, default: true
      t.integer    :position, null: false, default: 0
      t.timestamps
    end

    # A dealer shouldn't have two tax codes with the same display name; makes
    # picker UIs sane and prevents accidental duplicates.
    add_index :tax_codes, [:company_id, :name], unique: true
    add_index :tax_codes, [:company_id, :is_active, :position],
              name: 'idx_tax_codes_active_ordered'

    create_table :invoice_item_taxes do |t|
      t.references :invoice_item, null: false, foreign_key: true
      t.references :tax_code,     null: false, foreign_key: true
      t.decimal    :computed_amount, precision: 12, scale: 4, null: false, default: 0
      t.decimal    :computed_rate,   precision: 8, scale: 5,  null: false, default: 0
      t.decimal    :taxable_base,    precision: 12, scale: 4, null: false, default: 0
      t.timestamps
    end

    # A line + tax pairing should only appear once. If a user changes how much
    # of a tax applies they update the existing row.
    add_index :invoice_item_taxes, [:invoice_item_id, :tax_code_id],
              unique: true,
              name: 'idx_invoice_item_taxes_unique_pair'

    add_column :contacts, :tax_exempt,        :boolean, null: false, default: false
    add_column :contacts, :tax_exempt_reason, :string

    add_column :invoice_items, :skip_tax, :boolean, null: false, default: false
  end
end
