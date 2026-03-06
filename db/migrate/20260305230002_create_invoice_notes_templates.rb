class CreateInvoiceNotesTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :invoice_notes_templates do |t|
      t.bigint :company_id, null: false
      t.string :name, null: false
      t.text :notes, null: false
      t.boolean :is_default, default: false
      t.boolean :is_deleted, default: false
      t.timestamps
    end

    add_index :invoice_notes_templates, :company_id
  end
end
