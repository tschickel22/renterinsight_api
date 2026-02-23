class CreateAgreementCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :agreement_categories do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.string :color, default: '#6B7280'
      t.boolean :is_system, default: false, null: false
      t.integer :position, default: 0, null: false
      t.boolean :is_deleted, default: false, null: false
      t.timestamps
    end

    add_index :agreement_categories, [:company_id, :name], unique: true, where: "is_deleted = false", name: 'idx_agreement_categories_unique_name'
    add_index :agreement_categories, [:company_id, :is_deleted]
  end
end
