# frozen_string_literal: true

class AddApprovalToSocialPosts < ActiveRecord::Migration[8.0]
  def change
    change_table :social_posts, bulk: true do |t|
      t.datetime :approved_at
      t.bigint   :approved_by_id
    end

    add_index :social_posts, :approved_by_id
  end
end
