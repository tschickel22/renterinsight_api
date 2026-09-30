# frozen_string_literal: true

# TrueView layers: a rendering of one finish, cut down to the pixels that
# finish changed, so the buyer's page can stack any combination instantly.
class AddLayersToTruebuildRenders < ActiveRecord::Migration[8.0]
  def change
    add_column :truebuild_renders, :purpose, :string, null: false, default: 'full'
    add_column :truebuild_renders, :layer_url, :string
    add_column :truebuild_renders, :mask_coverage, :decimal, precision: 5, scale: 4
  end
end
