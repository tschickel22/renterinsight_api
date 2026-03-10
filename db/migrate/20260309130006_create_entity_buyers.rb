class CreateEntityBuyers < ActiveRecord::Migration[8.0]
  def change
    create_table :entity_buyers do |t|
      t.references :company, null: false, foreign_key: true
      t.references :contact, null: false, foreign_key: true
      t.string :buyable_type, null: false
      t.bigint :buyable_id, null: false
      t.string :role, null: false, default: 'co_buyer'
      t.integer :position, default: 0
      t.text :notes
      t.boolean :is_deleted, default: false
      t.timestamps
    end

    add_index :entity_buyers, [:buyable_type, :buyable_id],
              name: 'index_entity_buyers_on_buyable'
    add_index :entity_buyers, [:company_id, :buyable_type, :buyable_id],
              name: 'index_entity_buyers_on_company_buyable'
    add_index :entity_buyers, [:contact_id, :buyable_type, :buyable_id],
              name: 'index_entity_buyers_on_contact_buyable',
              unique: true
  end
end
