# frozen_string_literal: true

class AddZegoFieldsToLocations < ActiveRecord::Migration[8.0]
  def up
    # Only add if column doesn't exist
    unless column_exists?(:locations, :external_payments_property_id)
      add_column :locations, :external_payments_property_id, :string
      add_index :locations, :external_payments_property_id
    end
  end

  def down
    if column_exists?(:locations, :external_payments_property_id)
      remove_index :locations, :external_payments_property_id if index_exists?(:locations, :external_payments_property_id)
      remove_column :locations, :external_payments_property_id
    end
  end
end
