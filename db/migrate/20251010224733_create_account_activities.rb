class CreateAccountActivities < ActiveRecord::Migration[7.0]
  def change
    create_table :account_activities do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :activity_type, null: false
      t.text :description, null: false
      t.string :outcome
      t.integer :duration
      t.datetime :scheduled_date
      
      t.timestamps
    end

    add_index :account_activities, :activity_type
    add_index :account_activities, :outcome
    add_index :account_activities, :created_at
  end
end
