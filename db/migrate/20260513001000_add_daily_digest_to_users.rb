class AddDailyDigestToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :daily_digest_enabled, :boolean, default: true
    add_column :users, :daily_digest_hour, :integer, default: 7
    add_column :users, :daily_digest_last_sent_at, :datetime
  end
end
