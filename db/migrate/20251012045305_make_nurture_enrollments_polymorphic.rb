class MakeNurtureEnrollmentsPolymorphic < ActiveRecord::Migration[7.2]
  def up
    # Add polymorphic columns
    add_column :nurture_enrollments, :enrollable_type, :string
    add_column :nurture_enrollments, :enrollable_id, :integer
    
    # Add composite index for polymorphic association
    add_index :nurture_enrollments, [:enrollable_type, :enrollable_id]
    
    # Migrate existing data - all current enrollments are for Leads
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE nurture_enrollments 
          SET enrollable_type = 'Lead', 
              enrollable_id = lead_id 
          WHERE lead_id IS NOT NULL
        SQL
      end
    end
    
    # Make lead_id optional (for backward compatibility)
    change_column_null :nurture_enrollments, :lead_id, true
    
    # SQLite doesn't support ADD CONSTRAINT after table creation
    # We'll enforce this at the model level instead
  end
  
  def down
    # Remove polymorphic columns
    remove_index :nurture_enrollments, [:enrollable_type, :enrollable_id]
    remove_column :nurture_enrollments, :enrollable_type
    remove_column :nurture_enrollments, :enrollable_id
    
    # Restore lead_id as required
    change_column_null :nurture_enrollments, :lead_id, false
  end
end
