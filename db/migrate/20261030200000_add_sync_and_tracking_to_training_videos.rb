# frozen_string_literal: true

# E88 round 2: training videos made on staging reach production by
# themselves (uid matches a video across servers), the help assistant
# searches their narration, plays are counted, and companies can require
# videos of their people.
class AddSyncAndTrackingToTrainingVideos < ActiveRecord::Migration[8.0]
  def change
    change_table :training_videos, bulk: true do |t|
      t.uuid :uid, null: false, default: -> { 'gen_random_uuid()' }
      t.text :transcript
      t.integer :public_views, null: false, default: 0
      # What production copied from staging: the staging file urls and when.
      t.jsonb :source_files, null: false, default: {}
      # Screens the video shows (routes and data-tour markers), so a change to
      # one of them says this video needs a look.
      t.jsonb :covers, null: false, default: {}
    end
    add_index :training_videos, :uid, unique: true

    # One row per person per video.
    create_table :training_video_views do |t|
      t.references :training_video, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :company_id
      t.integer :furthest_seconds, null: false, default: 0
      t.integer :watched_seconds, null: false, default: 0
      t.integer :plays, null: false, default: 0
      t.datetime :completed_at
      t.datetime :last_watched_at
      t.timestamps
    end
    add_index :training_video_views, %i[user_id training_video_id], unique: true
    add_index :training_video_views, :company_id

    # Videos a company requires of a person, by hand or for every new user.
    create_table :training_assignments do |t|
      t.bigint :company_id, null: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :training_video, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :assigned_by_id
      t.date :due_on
      t.string :source, null: false, default: 'manual'
      t.timestamps
    end
    add_index :training_assignments, %i[user_id training_video_id], unique: true
    add_index :training_assignments, :company_id
  end
end
