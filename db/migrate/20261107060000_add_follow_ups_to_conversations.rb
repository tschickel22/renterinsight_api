# frozen_string_literal: true

# Quinn AI follows up until a visit is set (E96, 2026-11-07): how many
# follow-ups it has sent since the buyer last wrote, when the clock started,
# and when the next is due. Additive only.
class AddFollowUpsToConversations < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :conversations, :follow_up_count, :integer, default: 0, null: false
    add_column :conversations, :follow_up_anchor_at, :datetime
    add_column :conversations, :next_follow_up_at, :datetime
    add_index :conversations, :next_follow_up_at, where: 'next_follow_up_at IS NOT NULL', algorithm: :concurrently
  end
end
