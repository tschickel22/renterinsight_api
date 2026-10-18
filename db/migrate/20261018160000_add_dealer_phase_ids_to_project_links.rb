# frozen_string_literal: true

# A hand-off can cover several phases for one fee (install and delivery, say),
# not only one phase or the whole project.
class AddDealerPhaseIdsToProjectLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :project_links, :dealer_phase_ids, :bigint, array: true, default: [], null: false
  end
end
