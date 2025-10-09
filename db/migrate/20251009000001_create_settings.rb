class CreateSettings < ActiveRecord::Migration[7.0]
  def change
    # Check if table already exists before creating
    unless table_exists?(:settings)
      create_table :settings do |t|
        t.string :scope_type, null: false
        t.integer :scope_id, null: false
        t.string :key, null: false
        t.text :value
        
        t.timestamps
      end
      
      add_index :settings, [:scope_type, :scope_id, :key], unique: true, name: 'index_settings_on_scope_and_key'
      add_index :settings, [:scope_type, :scope_id], name: 'index_settings_on_scope'
    end
  end
end
