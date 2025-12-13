class CreateLoginActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :login_activities do |t|
      t.integer :user_id, null: false
      t.string :user_type, default: 'User', null: false # 'User' or 'BuyerPortalAccess'
      t.string :ip_address
      t.text :user_agent
      t.datetime :logged_in_at, null: false

      t.timestamps
    end

    add_index :login_activities, :user_id
    add_index :login_activities, [:user_id, :user_type]
    add_index :login_activities, :logged_in_at
  end
end
