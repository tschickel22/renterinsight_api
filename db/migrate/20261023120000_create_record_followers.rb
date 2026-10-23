# frozen_string_literal: true

# Followers (backlog E86): extra reps on a lead, account, contact or deal who
# are told what the owner is told and can see the record outside their
# locations. A new table only, so it is safe while old code is still running.
class CreateRecordFollowers < ActiveRecord::Migration[8.0]
  def change
    create_table :record_followers do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.string :followable_type, null: false
      t.bigint :followable_id, null: false
      t.references :user, null: false, foreign_key: true, index: false
      t.bigint :created_by_id
      t.timestamps
    end

    add_index :record_followers, %i[followable_type followable_id user_id],
              unique: true, name: 'index_record_followers_unique'
    add_index :record_followers, %i[user_id followable_type followable_id],
              name: 'index_record_followers_on_user'
    add_index :record_followers, :company_id
  end
end
