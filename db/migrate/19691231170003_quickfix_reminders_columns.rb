class QuickfixRemindersColumns < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:reminders)

    add_column :reminders, :reminder_type, :string unless column_exists?(:reminders, :reminder_type)
    add_column :reminders, :due_date, :datetime unless column_exists?(:reminders, :due_date)
    add_column :reminders, :is_completed, :boolean, default: false unless column_exists?(:reminders, :is_completed)
    add_column :reminders, :completed_at, :datetime unless column_exists?(:reminders, :completed_at)
    add_column :reminders, :priority, :string, default: 'medium' unless column_exists?(:reminders, :priority)
    add_column :reminders, :user_id, :integer unless column_exists?(:reminders, :user_id)
    add_column :reminders, :lead_id, :integer unless column_exists?(:reminders, :lead_id)

    add_index :reminders, :lead_id unless index_exists?(:reminders, :lead_id)
    add_index :reminders, :user_id unless index_exists?(:reminders, :user_id)
    add_index :reminders, :due_date unless index_exists?(:reminders, :due_date)
  end

  def down
    # no-op (safe quickfix)
  end
end
