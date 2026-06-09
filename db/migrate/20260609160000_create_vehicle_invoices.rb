class CreateVehicleInvoices < ActiveRecord::Migration[8.0]
  def change
    create_table :vehicle_invoices do |t|
      # One invoice per vehicle (enforced by the unique index). Company-scoped for
      # tenant isolation; company_id is set once at creation and never changes.
      t.references :vehicle, null: false, foreign_key: true, index: { unique: true }
      t.references :company, null: false, foreign_key: true

      # Manufacturer-invoice money fields (decimal 15,2).
      t.decimal :gross_invoice,      precision: 15, scale: 2
      t.decimal :base_price,         precision: 15, scale: 2
      t.decimal :options_total,      precision: 15, scale: 2
      t.decimal :material_surcharge, precision: 15, scale: 2
      t.decimal :factory_freight,    precision: 15, scale: 2
      t.decimal :sales_allowance,    precision: 15, scale: 2 # stored NEGATIVE for a rebate/allowance
      t.decimal :hud_fees,           precision: 15, scale: 2
      t.decimal :state_assoc_fees,   precision: 15, scale: 2
      t.decimal :tax_from_invoice,   precision: 15, scale: 2
      t.decimal :total_invoice,      precision: 15, scale: 2
      t.decimal :nada_base,          precision: 15, scale: 2 # used homes

      # Coded fields.
      t.integer :vep_code  # 0/1/2
      t.integer :wind_zone # 1/2/3

      # Invoice header metadata.
      t.string :invoice_number
      t.date   :invoice_date
      t.string :manufacturer

      # The scanned invoice file lives as a VehicleDocument flagged internal-only
      # (visibility:'internal'). Nullable — no scan in this phase, association reserved.
      t.bigint :scanned_document_id

      t.timestamps
    end

    add_index :vehicle_invoices, :scanned_document_id
    add_foreign_key :vehicle_invoices, :vehicle_documents,
                    column: :scanned_document_id, on_delete: :nullify
  end
end
