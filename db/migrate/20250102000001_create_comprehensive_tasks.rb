class CreateComprehensiveTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :tasks do |t|
      # Company scoping (required)
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true
      
      # Polymorphic association (optional - can be standalone task)
      t.string :taskable_type
      t.bigint :taskable_id
      t.index [:taskable_type, :taskable_id], name: 'index_tasks_on_taskable'
      
      # Core task fields
      t.string :title, null: false
      t.text :description
      
      # Status & Priority
      t.integer :status, default: 0, null: false  # pending=0, in_progress=1, on_hold=2, completed=3, cancelled=4
      t.integer :priority, default: 1, null: false  # low=0, medium=1, high=2, urgent=3
      
      # Module classification
      t.string :task_module  # crm, service, delivery, finance, warranty, quote, pdi, general
      
      # Assignment
      t.references :assigned_to, foreign_key: { to_table: :users }, null: true
      
      # Dates
      t.datetime :due_date
      t.datetime :completed_at
      
      # Metadata
      t.string :source_type  # Where task originated: 'lead', 'service_ticket', 'user_created', etc.
      t.string :source_id    # Original record ID for reference
      t.string :link         # Deep link to related entity
      t.jsonb :tags, default: []
      t.jsonb :custom_fields, default: {}
      
      # Audit fields
      t.string :created_by
      t.string :updated_by
      
      t.timestamps
    end
    
    # Indexes for common queries
    add_index :tasks, [:company_id, :status], name: 'index_tasks_on_company_and_status'
    add_index :tasks, [:company_id, :assigned_to_id], name: 'index_tasks_on_company_and_assigned_to'
    add_index :tasks, [:company_id, :task_module], name: 'index_tasks_on_company_and_module'
    add_index :tasks, [:company_id, :location_id], name: 'index_tasks_on_company_and_location'
    add_index :tasks, [:due_date], name: 'index_tasks_on_due_date'
    add_index :tasks, [:status, :due_date], name: 'index_tasks_on_status_and_due_date'
  end
end
