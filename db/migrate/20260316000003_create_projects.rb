class CreateProjects < ActiveRecord::Migration[8.0]
  def change
    create_table :projects do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, foreign_key: true
      t.references :deal, foreign_key: true                   # Source deal (optional — some projects may be standalone)
      t.references :project_template, foreign_key: true       # Template used to create this project
      t.string :name, null: false                             # e.g., "Locy/Wagner - Adventure Mojave"
      t.string :project_number                                # Auto-generated: P-000001
      t.text :description
      t.string :status, default: 'active', null: false        # active, completed, on_hold, cancelled
      t.bigint :current_phase_id                              # FK to project_phases — quick "where are we" lookup
      t.integer :phase_count, default: 0                      # Cached total phase count
      t.integer :completed_phase_count, default: 0            # Cached completed phase count
      t.integer :progress_percent, default: 0                 # Cached 0-100 progress

      # Key dates
      t.date :started_at
      t.date :estimated_completion_date
      t.date :actual_completion_date

      # Customer info (denormalized from Deal for quick display)
      t.string :customer_name
      t.string :customer_email
      t.string :customer_phone

      # Home info (denormalized from Deal/Vehicle for quick display)
      t.string :home_make
      t.string :home_model
      t.string :home_serial_number
      t.bigint :vehicle_id                                    # Link to vehicle/inventory record

      # Delivery address (from deal or manual entry)
      t.string :delivery_street
      t.string :delivery_city
      t.string :delivery_state
      t.string :delivery_zip

      # Ownership
      t.bigint :owner_id                                      # Primary project manager (User)
      t.bigint :created_by_id                                 # User who created this project

      # Visibility
      t.boolean :client_visible, default: true                # Show in client portal?
      t.string :client_access_token                           # Token for public/portal progress view

      t.boolean :is_deleted, default: false
      t.jsonb :custom_field_values, default: {}, null: false  # Custom fields (per Section 24 pattern)
      t.timestamps
    end

    add_index :projects, [:company_id, :status], name: 'idx_projects_company_status'
    add_index :projects, [:company_id, :location_id], name: 'idx_projects_company_location'
    add_index :projects, [:company_id, :project_number], name: 'idx_projects_company_number', unique: true
    add_index :projects, :deal_id, name: 'idx_projects_deal'
    add_index :projects, :owner_id, name: 'idx_projects_owner'
    add_index :projects, :vehicle_id, name: 'idx_projects_vehicle'
    add_index :projects, :current_phase_id, name: 'idx_projects_current_phase'
    add_index :projects, :client_access_token, name: 'idx_projects_client_token', unique: true
    add_index :projects, :status, name: 'idx_projects_status'
    add_index :projects, :is_deleted, name: 'idx_projects_deleted'
    add_index :projects, :custom_field_values, using: :gin, name: 'idx_projects_custom_fields'
  end
end
