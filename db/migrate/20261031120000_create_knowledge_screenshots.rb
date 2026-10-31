# frozen_string_literal: true

# Screenshots in help articles that keep themselves current (backlog E89).
# A row is a recipe (page, clicks, element to crop to) plus the pictures the
# nightly run took of it, at desktop and mobile size. An article shows one
# with a line of its own: {{shot: key}}. Platform content: no company_id.
class CreateKnowledgeScreenshots < ActiveRecord::Migration[8.0]
  def change
    create_table :knowledge_screenshots do |t|
      t.string :key, null: false
      t.string :module_key
      t.string :title
      t.string :alt_text
      # The recipe.
      t.string :route, null: false
      t.jsonb :steps, null: false, default: []
      t.string :crop_marker
      t.integer :padding, null: false, default: 16
      t.jsonb :mobile_steps
      t.string :mobile_crop_marker
      t.jsonb :mask_selectors, null: false, default: []
      # The pictures, one set per size.
      %w[desktop mobile].each do |size|
        t.string :"#{size}_url"
        t.string :"#{size}_previous_url"
        t.string :"#{size}_status", null: false, default: 'pending'
        t.string :"#{size}_error"
        t.float :"#{size}_change_score"
        t.integer :"#{size}_width"
        t.integer :"#{size}_height"
      end
      t.datetime :captured_at
      # The frontend build the current pictures were taken on, so production
      # only takes a picture once its own build has caught up.
      t.string :commit_sha
      t.datetime :commit_at
      # A big change since the article's text was last checked.
      t.boolean :needs_review, null: false, default: false
      t.datetime :changed_at
      # Where the recipe came from: db/guide/screenshots.yml, or Knowledge admin.
      t.string :source, null: false, default: 'admin'
      # On production: what was last copied from staging.
      t.jsonb :source_files, null: false, default: {}
      t.timestamps
    end
    add_index :knowledge_screenshots, :key, unique: true
    add_index :knowledge_screenshots, :module_key
  end
end
