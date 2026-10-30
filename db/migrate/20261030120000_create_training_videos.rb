# frozen_string_literal: true

# Training videos in the help center (E88). Files live in the public assets
# bucket; a share token gives a watch page that needs no sign-in.
class CreateTrainingVideos < ActiveRecord::Migration[8.0]
  def change
    create_table :training_videos do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.string :module_key
      t.integer :position, null: false, default: 0
      t.integer :duration_seconds
      t.string :video_url
      t.string :video_key
      t.bigint :video_size
      t.string :poster_url
      t.string :captions_url
      t.jsonb :chapters, null: false, default: []
      t.boolean :is_published, null: false, default: false
      t.string :share_token, null: false
      t.boolean :share_enabled, null: false, default: true
      t.timestamps
    end
    add_index :training_videos, :slug, unique: true
    add_index :training_videos, :share_token, unique: true
    add_index :training_videos, %i[module_key position]
  end
end
