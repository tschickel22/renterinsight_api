# frozen_string_literal: true

# What goes with a job handed to a linked installer when the dealer bid it
# first: the awarded bids with their contractors, the bid amounts as phase
# budgets only, or nothing (ProjectLinkHandover).
class AddHandoverToProjectLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :project_links, :handover_mode, :string
    add_column :project_links, :handover_bids, :jsonb, default: [], null: false
  end
end
