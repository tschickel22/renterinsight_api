class CreateAgreements < ActiveRecord::Migration[8.0]
  def change
    create_table :agreements do |t|
      t.references :company, null: false, foreign_key: true
      t.references :agreement_template, foreign_key: true, null: true
      t.string :title, null: false
      t.text :description
      t.string :agreement_number, null: false
      t.string :category
      t.string :status, default: 'draft', null: false
      t.string :document_url          # Original uploaded/generated document (S3)
      t.string :sealed_document_url   # Final sealed PDF after all signatures (S3)
      t.text :content                 # Rich text content (for editor-built agreements)
      t.string :content_type, default: 'upload', null: false  # 'upload' or 'editor'
      t.jsonb :merge_field_values, default: {}    # Resolved merge data
      t.jsonb :field_placements, default: []      # Signature/form field positions on PDF
      t.integer :prepared_by_id
      t.datetime :expires_at
      t.datetime :sent_at
      t.datetime :completed_at
      t.datetime :voided_at
      t.datetime :declined_at
      t.integer :voided_by_id
      t.text :void_reason
      t.integer :version, default: 1, null: false
      t.integer :parent_agreement_id   # Self-ref for version tracking
      t.integer :reminder_frequency_days, default: 3
      t.datetime :last_reminder_sent_at
      t.references :location, foreign_key: true, null: true
      t.jsonb :metadata, default: {}
      t.boolean :is_deleted, default: false, null: false
      t.timestamps
    end

    add_index :agreements, [:company_id, :status, :is_deleted], name: 'idx_agreements_company_status'
    add_index :agreements, [:company_id, :agreement_number], unique: true, name: 'idx_agreements_unique_number'
    add_index :agreements, :parent_agreement_id
    add_index :agreements, :expires_at
    add_index :agreements, :prepared_by_id
    add_index :agreements, :voided_by_id
    add_index :agreements, [:company_id, :category], name: 'idx_agreements_company_category'
    add_index :agreements, [:status, :expires_at], name: 'idx_agreements_expiry_check', where: "status IN ('sent', 'viewed', 'partially_signed')"
  end
end
