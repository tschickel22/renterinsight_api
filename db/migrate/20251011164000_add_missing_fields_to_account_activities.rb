class AddMissingFieldsToAccountActivities < ActiveRecord::Migration[7.0]
  def change
    # Add missing columns to match the model
    add_column :account_activities, :assigned_to_id, :bigint
    add_column :account_activities, :related_activity_id, :bigint
    add_column :account_activities, :subject, :string
    add_column :account_activities, :status, :string
    add_column :account_activities, :priority, :string
    add_column :account_activities, :due_date, :datetime
    add_column :account_activities, :start_time, :datetime
    add_column :account_activities, :end_time, :datetime
    add_column :account_activities, :duration_minutes, :integer
    add_column :account_activities, :completed_at, :datetime
    add_column :account_activities, :call_direction, :string
    add_column :account_activities, :call_outcome, :string
    add_column :account_activities, :phone_number, :string
    add_column :account_activities, :meeting_location, :string
    add_column :account_activities, :meeting_link, :string
    add_column :account_activities, :meeting_attendees, :text
    add_column :account_activities, :reminder_method, :text # Will be serialized as JSON
    add_column :account_activities, :reminder_time, :datetime
    add_column :account_activities, :reminder_sent, :boolean, default: false
    add_column :account_activities, :estimated_hours, :float
    add_column :account_activities, :actual_hours, :float
    add_column :account_activities, :outcome_notes, :text
    add_column :account_activities, :metadata, :json
    
    # Add foreign key constraints
    add_foreign_key :account_activities, :users, column: :assigned_to_id
    add_foreign_key :account_activities, :account_activities, column: :related_activity_id
    
    # Add indexes for performance
    add_index :account_activities, :assigned_to_id
    add_index :account_activities, :related_activity_id
    add_index :account_activities, :status
    add_index :account_activities, :priority
    add_index :account_activities, :due_date
    add_index :account_activities, :completed_at
  end
end
