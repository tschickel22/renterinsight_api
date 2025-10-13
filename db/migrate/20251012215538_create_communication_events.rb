class CreateCommunicationEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :communication_events do |t|
      t.references :communication, null: false, foreign_key: true, index: true
      
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      
      t.string :ip_address
      t.string :user_agent
      
      t.text :details  # text instead of jsonb for SQLite
      
      t.timestamps
    end
    
    add_index :communication_events, :event_type
    add_index :communication_events, :occurred_at
    add_index :communication_events, [:communication_id, :event_type],
              name: 'idx_events_on_communication_and_type'
  end
end
