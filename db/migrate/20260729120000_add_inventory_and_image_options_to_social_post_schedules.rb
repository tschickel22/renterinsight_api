# frozen_string_literal: true

# Scheduled social posts previously hardcoded `status: 'available'` when picking
# a unit to feature, and had no say in whether that unit needed photos. Catalog
# homes (available_to_order) could therefore never be featured, and a photoless
# unit produced a post with an empty image_urls array that still went out.
#
# These columns move all of that onto the schedule:
#   inventory_statuses — which statuses the picker may draw from
#   require_photos     — only feature units that actually have images
#   image_pool         — operator-supplied images reused across future posts
#   image_pool_cursor  — round-robin position so the pool rotates, not repeats
#   use_logo_fallback  — opt-in: fall back to the company logo when there is no
#                        image at all. Off means the post stays imageless.
class AddInventoryAndImageOptionsToSocialPostSchedules < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_schedules, :inventory_statuses, :jsonb, default: ['available'], null: false
    add_column :social_post_schedules, :require_photos,     :boolean, default: false, null: false
    add_column :social_post_schedules, :image_pool,         :jsonb, default: [], null: false
    add_column :social_post_schedules, :image_pool_cursor,  :integer, default: 0, null: false
    add_column :social_post_schedules, :use_logo_fallback,  :boolean, default: false, null: false
  end
end
