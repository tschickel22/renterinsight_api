# frozen_string_literal: true

# Where each surface is in a model's photo (the cabinets, the countertop,
# the siding), found once per photo. A TrueView layer paints only inside its
# surface's mask, so every color of a surface fills the same outline and
# nothing outside it (stools, floor, lawn) is touched.
class CreateTruebuildSurfaceMasks < ActiveRecord::Migration[8.0]
  def change
    create_table :truebuild_surface_masks do |t|
      t.string :source_url, null: false
      t.string :surface, null: false
      t.integer :version, null: false, default: 1
      t.string :status, null: false, default: 'done'
      t.string :mask_url
      t.decimal :coverage, precision: 5, scale: 4
      t.string :model
      t.text :error
      t.jsonb :usage, null: false, default: {}
      t.timestamps
    end
    add_index :truebuild_surface_masks, %i[source_url surface version], unique: true, name: 'idx_truebuild_surface_masks_unique'
  end
end
