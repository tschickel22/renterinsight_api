class CreateNotes < ActiveRecord::Migration[7.0]
  def change
    create_table :notes do |t|
      t.text :content, null: false
      t.string :entity_type, null: false
      t.string :entity_id, null: false
      t.references :user, foreign_key: true
      t.string :created_by_name
      
      t.timestamps
    end

    add_index :notes, [:entity_type, :entity_id]
    add_index :notes, :created_at
  end
end
