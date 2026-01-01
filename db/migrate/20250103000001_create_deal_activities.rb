class CreateDealActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :deal_activities do |t|
      t.references :deal, null: false, foreign_key: true
      t.references :user, foreign_key: true # creator
      t.references :assigned_to, foreign_key: { to_table: :users }
      t.references :related_activity, foreign_key: { to_table: :deal_activities }
      
      # Activity metadata
      t.string :activity_type, null: false # task, meeting, call, reminder, email, note, status_change
      t.string :subject
      t.text :description
      t.string :status # pending, in_progress, completed, cancelled
      t.string :priority # low, medium, high, urgent
      
      # Timing
      t.datetime :due_date
      t.datetime :start_time
      t.datetime :end_time
      t.datetime :completed_at
      
      # Call-specific fields
      t.string :phone_number
      t.string :call_direction # inbound, outbound
      t.string :call_outcome # answered, voicemail, no_answer, busy
      t.integer :duration # in seconds
      
      # Meeting-specific fields
      t.string :location
      t.string :meeting_link
      t.text :attendees
      
      # Outcome
      t.string :outcome # positive, neutral, negative
      
      # Reminder fields
      t.datetime :reminder_time
      t.json :reminder_method # ["email", "popup", "sms"]
      t.boolean :reminder_sent, default: false

      t.timestamps
    end

    add_index :deal_activities, :activity_type
    add_index :deal_activities, :status
    add_index :deal_activities, :priority
    add_index :deal_activities, :due_date
    add_index :deal_activities, :reminder_time
  end
end
