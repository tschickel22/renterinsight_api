class CreateAgreementTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :agreement_templates do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.string :category
      t.references :agreement_category, foreign_key: true, null: true
      t.string :document_url
      t.text :content  # Rich text template content (for editor-built templates)
      t.string :template_type, default: 'upload', null: false  # 'upload' or 'editor'
      t.jsonb :merge_fields, default: {}       # Available merge field definitions
      t.jsonb :field_placements, default: []   # x,y,page,type for signature/form fields
      t.jsonb :default_signers, default: []    # Role-based signer slot definitions
      t.string :status, default: 'draft', null: false
      t.integer :version, default: 1, null: false
      t.boolean :is_system_template, default: false, null: false
      t.references :location, foreign_key: true, null: true
      t.integer :created_by_id
      t.boolean :is_deleted, default: false, null: false
      t.timestamps
    end

    add_index :agreement_templates, [:company_id, :status, :is_deleted], name: 'idx_agr_templates_company_status'
    add_index :agreement_templates, [:company_id, :category], name: 'idx_agr_templates_company_category'
    add_index :agreement_templates, :created_by_id
  end
end
