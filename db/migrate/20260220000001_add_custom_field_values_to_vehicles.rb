# frozen_string_literal: true

class AddCustomFieldValuesToVehicles < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:vehicles, :custom_field_values)
      add_column :vehicles, :custom_field_values, :jsonb, default: {}, null: false
    end
  end
end
