# frozen_string_literal: true

class AddBudgetFieldsToProjectPhases < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:project_phases, :estimated_budget)
      add_column :project_phases, :estimated_budget, :decimal, precision: 12, scale: 2
    end

    unless column_exists?(:project_phases, :actual_cost)
      add_column :project_phases, :actual_cost, :decimal, precision: 12, scale: 2, default: 0
    end
  end
end
