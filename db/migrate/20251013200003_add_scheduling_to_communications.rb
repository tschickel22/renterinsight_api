class AddSchedulingToCommunications < ActiveRecord::Migration[7.0]
  def change
    add_column :communications, :scheduled_for, :datetime
    add_column :communications, :scheduled_status, :string, default: 'immediate'
    add_column :communications, :scheduled_job_id, :string
    
    add_index :communications, :scheduled_for
    add_index :communications, :scheduled_status
    add_index :communications, [:scheduled_status, :scheduled_for]
  end
end
