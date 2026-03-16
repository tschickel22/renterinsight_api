class CreateProjectPhases < ActiveRecord::Migration[8.0]
  def change
    create_table :project_phases do |t|
      t.references :project, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true   # Denormalized for tenant isolation queries
      t.string :name, null: false                             # e.g., "Home Ordered", "Installation"
      t.text :description                                     # What happens in this phase
      t.integer :position, null: false, default: 0            # Display order (1, 2, 3...)
      t.string :status, default: 'not_started', null: false   # not_started, in_progress, completed, skipped
      t.boolean :is_required, default: true                   # Can this phase be skipped?

      # Dates
      t.datetime :started_at
      t.datetime :completed_at
      t.date :estimated_start_date
      t.date :estimated_completion_date
      t.integer :estimated_days                               # Inherited from template, can be overridden

      # Client visibility & notifications
      t.boolean :visible_to_client, default: true             # Show in client portal?
      t.boolean :notify_client_on_start, default: false       # Send email/SMS when phase starts
      t.boolean :notify_client_on_complete, default: true     # Send email/SMS when phase completes
      t.boolean :client_notified_start, default: false        # Has start notification been sent?
      t.boolean :client_notified_complete, default: false     # Has completion notification been sent?

      # Notes
      t.text :notes                                           # Internal notes from staff
      t.text :client_notes                                    # Notes visible to client in portal

      # Display
      t.string :icon                                          # Lucide icon name
      t.string :color                                         # Hex color

      # Who completed this phase
      t.bigint :completed_by_id                               # User who marked phase complete

      t.timestamps
    end

    add_index :project_phases, [:project_id, :position], name: 'idx_project_phases_project_position'
    add_index :project_phases, [:project_id, :status], name: 'idx_project_phases_project_status'
    add_index :project_phases, [:company_id, :status], name: 'idx_project_phases_company_status'
    add_index :project_phases, :status, name: 'idx_project_phases_status'
  end
end
