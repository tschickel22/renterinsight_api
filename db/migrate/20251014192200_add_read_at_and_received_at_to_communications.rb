class AddReadAtAndReceivedAtToCommunications < ActiveRecord::Migration[7.2]
  def change
    add_column :communications, :read_at, :datetime
    add_column :communications, :received_at, :datetime
  end
end
