class CreateProjectTemplatePhases < ActiveRecord::Migration[8.0]
  def change
    create_table :project_template_phases do |t|
      t.references :project_template, null: false, foreign_key: true
      t.string :name, null: false                             # e.g., "Home Ordered", "Installation"
      t.text :description                                     # What happens in this phase
      t.integer :position, null: false, default: 0            # Display order (1, 2, 3...)
      t.boolean :visible_to_client, default: true             # Show in client portal?
      t.boolean :is_required, default: true                   # Can this phase be skipped?
      t.boolean :notify_client_on_start, default: false       # Send email/SMS when phase starts
      t.boolean :notify_client_on_complete, default: true     # Send email/SMS when phase completes
      t.integer :estimated_days                               # Default estimated duration in days
      t.string :icon                                          # Lucide icon name for display
      t.string :color                                         # Hex color for visual display
      t.timestamps
    end

    add_index :project_template_phases, [:project_template_id, :position], name: 'idx_template_phases_template_position'
  end
end
