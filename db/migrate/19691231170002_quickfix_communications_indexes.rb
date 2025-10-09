class QuickfixCommunicationsIndexes < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:communication_logs)
    add_index :communication_logs, :lead_id unless index_exists?(:communication_logs, :lead_id)
    add_index :communication_logs, :sent_at unless index_exists?(:communication_logs, :sent_at)
  end

  def down
    # no-op
  end
end
