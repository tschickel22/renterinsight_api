# frozen_string_literal: true

class AddContractorIdToProjectCostItems < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:project_cost_items, :contractor_id)
      add_reference :project_cost_items, :contractor, null: true, foreign_key: { on_delete: :nullify }
    end
  end
end
