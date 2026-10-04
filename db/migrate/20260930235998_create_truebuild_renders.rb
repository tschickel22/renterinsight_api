# frozen_string_literal: true

# TrueView: AI edits of a model's real photos in the finishes a buyer picked.
# One row per source photo, finish selection and image model, so a
# combination is paid for once and served from the cache after that.
class CreateTruebuildRenders < ActiveRecord::Migration[8.0]
  def change
    create_table :truebuild_renders do |t|
      t.references :catalog_plan_variant, foreign_key: { on_delete: :nullify }
      t.string :room
      t.string :source_url, null: false
      t.jsonb :selection, null: false, default: []
      t.string :selection_key, null: false
      t.string :model_key, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :status, null: false, default: 'queued'
      t.string :image_url
      t.decimal :cost_usd, precision: 10, scale: 4
      t.integer :latency_ms
      t.jsonb :usage, null: false, default: {}
      t.text :prompt
      t.text :error
      t.string :lab_run
      t.timestamps
    end
    add_index :truebuild_renders, %i[source_url selection_key model_key]
    add_index :truebuild_renders, :lab_run
  end
end
