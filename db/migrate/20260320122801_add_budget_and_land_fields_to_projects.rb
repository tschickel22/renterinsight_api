# frozen_string_literal: true

class AddBudgetAndLandFieldsToProjects < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:projects, :budget_amount)
      add_column :projects, :budget_amount, :decimal, precision: 12, scale: 2
    end

    unless column_exists?(:projects, :actual_cost)
      add_column :projects, :actual_cost, :decimal, precision: 12, scale: 2, default: 0
    end

    unless column_exists?(:projects, :labor_cost)
      add_column :projects, :labor_cost, :decimal, precision: 12, scale: 2, default: 0
    end

    unless column_exists?(:projects, :materials_cost)
      add_column :projects, :materials_cost, :decimal, precision: 12, scale: 2, default: 0
    end

    unless column_exists?(:projects, :subcontractor_cost)
      add_column :projects, :subcontractor_cost, :decimal, precision: 12, scale: 2, default: 0
    end

    unless column_exists?(:projects, :other_cost)
      add_column :projects, :other_cost, :decimal, precision: 12, scale: 2, default: 0
    end

    unless column_exists?(:projects, :land_parcel_id)
      add_reference :projects, :land_parcel, null: true, foreign_key: { on_delete: :nullify }
    end
  end
end
