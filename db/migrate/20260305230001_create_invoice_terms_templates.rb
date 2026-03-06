class CreateInvoiceTermsTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :invoice_terms_templates do |t|
      t.bigint :company_id, null: false
      t.string :name, null: false
      t.text :terms, null: false
      t.boolean :is_default, default: false
      t.boolean :is_deleted, default: false
      t.timestamps
    end

    add_index :invoice_terms_templates, :company_id
    add_index :invoice_terms_templates, [:company_id, :is_default], name: 'idx_terms_templates_company_default'
  end
end
