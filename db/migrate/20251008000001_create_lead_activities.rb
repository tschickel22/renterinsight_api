# frozen_string_literal: true

class CreateLeadActivities < ActiveRecord::Migration[7.0]
  def change
    create_table :lead_activities do |t|
      t.references :lead, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :assigned_to, foreign_key: { to_table: :users }
      
      # Core fields
      t.string :activity_type, null: false # task, meeting, call, reminder
      t.string :subject, null: false
      t.text :description
      t.string :status, default: 'pending' # pending, in_progress, completed, cancelled
      t.string :priority, default: 'medium' # low, medium, high, urgent
      
      # Scheduling
      t.datetime :due_date
      t.datetime :start_time
      t.datetime :end_time
      t.integer :duration_minutes
      t.datetime :completed_at
      
      # Call specific
      t.string :call_direction # inbound, outbound
      t.string :call_outcome # answered, voicemail, no_answer, busy
      t.string :phone_number
      
      # Meeting specific
      t.string :meeting_location
      t.string :meeting_link
      t.text :meeting_attendees # JSON string
      
      # Reminder specific
      t.text :reminder_method # JSON string array: ["email", "popup", "sms"]
      t.datetime :reminder_time
      t.boolean :reminder_sent, default: false
      
      # Task specific
      t.integer :estimated_hours
      t.integer :actual_hours
      
      # Relations
      t.references :related_activity, foreign_key: { to_table: :lead_activities }
      
      # Metadata
      t.json :metadata, default: {}
      t.text :outcome_notes
      
      t.timestamps
    end
    
    add_index :lead_activities, [:lead_id, :activity_type]
    add_index :lead_activities, [:assigned_to_id, :status]
    add_index :lead_activities, :due_date
    add_index :lead_activities, :start_time
  end
end
