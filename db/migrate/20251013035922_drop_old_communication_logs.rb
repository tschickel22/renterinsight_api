class DropOldCommunicationLogs < ActiveRecord::Migration[7.0]
  def change
    drop_table :communication_logs if table_exists?(:communication_logs)
  end
end
