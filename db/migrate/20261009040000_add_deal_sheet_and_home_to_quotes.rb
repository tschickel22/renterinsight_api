# frozen_string_literal: true

# A quote built from a Deal Sheet remembers which version it came from (a
# draft can be quoted too), and a quote can show the home: its photos,
# floor plan and details (backlog E73).
class AddDealSheetAndHomeToQuotes < ActiveRecord::Migration[8.0]
  def change
    add_reference :quotes, :deal_home_build, foreign_key: { on_delete: :nullify }, index: true
    add_column :quotes, :deal_sheet_version, :integer
    add_column :quotes, :show_home, :boolean, null: false, default: false
  end
end
