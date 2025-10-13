class CreateCommunicationThreads < ActiveRecord::Migration[7.0]
  def change
    create_table :communication_threads do |t|
      t.string :subject
      t.string :channel, null: false
      t.string :status, default: 'active', null: false
      t.datetime :last_message_at
      t.text :metadata  # text instead of jsonb for SQLite
      
      t.timestamps
    end
    
    add_index :communication_threads, :channel
    add_index :communication_threads, :status
    add_index :communication_threads, :last_message_at
  end
end
