class AddParticipantToCommunicationThreads < ActiveRecord::Migration[7.0]
  def change
    add_column :communication_threads, :participant_type, :string
    add_column :communication_threads, :participant_id, :bigint
    
    add_index :communication_threads, [:participant_type, :participant_id],
              name: 'index_comm_threads_on_participant'
    
    change_column_null :communication_threads, :channel, true
  end
end
