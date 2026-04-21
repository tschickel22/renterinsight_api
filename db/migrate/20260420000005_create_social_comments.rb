# frozen_string_literal: true

class CreateSocialComments < ActiveRecord::Migration[8.0]
  def change
    create_table :social_comments do |t|
      t.bigint   :company_id,          null: false
      t.bigint   :social_post_id,      null: false
      t.string   :external_comment_id, null: false
      t.string   :external_post_id
      t.string   :platform
      t.string   :author_name
      t.string   :author_id
      t.string   :author_profile_pic
      t.text     :message
      t.string   :parent_comment_id
      t.boolean  :is_reply,     default: false
      t.string   :status,       default: 'active'
      t.boolean  :is_from_page, default: false
      t.bigint   :replied_by_user_id
      t.datetime :commented_at
      t.datetime :read_at
      t.jsonb    :metadata,     default: {}
      t.boolean  :is_deleted,   default: false

      t.timestamps
    end

    add_index :social_comments, [:company_id, :social_post_id]
    add_index :social_comments, :external_comment_id, unique: true
    add_index :social_comments, :external_post_id
    add_index :social_comments, [:company_id, :status]
    add_index :social_comments, [:company_id, :read_at]
  end
end
