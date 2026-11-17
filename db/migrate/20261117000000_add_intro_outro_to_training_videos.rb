# frozen_string_literal: true

# Where a video's own intro ends and its outro starts, in seconds. "Watch all"
# plays an area as one course and skips both; a single video still plays whole.
# Null means play from the start and to the end, which is how every video
# behaves today.
class AddIntroOutroToTrainingVideos < ActiveRecord::Migration[8.0]
  def change
    add_column :training_videos, :intro_ends_at, :integer
    add_column :training_videos, :outro_starts_at, :integer
  end
end
