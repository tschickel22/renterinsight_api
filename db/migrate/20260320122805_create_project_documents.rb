# frozen_string_literal: true

class CreateProjectDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :project_documents do |t|
      t.references :company, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :documentable_type
      t.bigint :documentable_id
      t.references :uploaded_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :title, null: false
      t.text :description
      t.string :category, null: false
      t.string :file_url, null: false
      t.string :file_s3_key, null: false
      t.string :file_name, null: false
      t.integer :file_size
      t.string :content_type
      t.boolean :is_deleted, default: false
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :project_documents, [:documentable_type, :documentable_id], name: 'index_project_documents_on_documentable'
    add_index :project_documents, :category
  end
end
