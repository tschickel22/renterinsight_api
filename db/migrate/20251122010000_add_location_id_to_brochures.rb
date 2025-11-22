# frozen_string_literal: true

class AddLocationIdToBrochures < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:brochures, :location_id)
      add_column :brochures, :location_id, :bigint
      add_index :brochures, :location_id
      add_index :brochures, [:company_id, :location_id]
    end
  end
end
