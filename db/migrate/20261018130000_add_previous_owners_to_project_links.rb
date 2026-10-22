# frozen_string_literal: true

# Who the dealer had on the project and phases before handing them to a linked
# installer, so taking the job back or a decline puts them back.
class AddPreviousOwnersToProjectLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :project_links, :previous_owners, :jsonb, null: false, default: {}
  end
end
