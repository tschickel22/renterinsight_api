# frozen_string_literal: true

# Settings a Deal Sheet keeps beside its lines (backlog E49/E51). First use:
# color_skips, the color and finish sets the rep marked "Not on this home"
# (the colors for an option the home does not have), so the factory PO says
# so instead of "Not chosen yet".
class AddMetadataToDealHomeBuilds < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_home_builds, :metadata, :jsonb, null: false, default: {}
  end
end
