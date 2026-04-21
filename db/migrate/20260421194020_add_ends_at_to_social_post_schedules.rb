class AddEndsAtToSocialPostSchedules < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_schedules, :ends_at, :datetime
  end
end
