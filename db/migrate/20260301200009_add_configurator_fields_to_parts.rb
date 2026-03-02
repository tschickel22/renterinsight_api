# frozen_string_literal: true

class AddConfiguratorFieldsToParts < ActiveRecord::Migration[8.0]
  def change
    add_reference :parts, :factory, foreign_key: true
    add_reference :parts, :floor_plan, foreign_key: true
    add_column :parts, :is_configured_home, :boolean, default: false
    add_column :parts, :vin, :string
    add_column :parts, :serial_number, :string

    add_index :parts, :is_configured_home
    add_index :parts, [:floor_plan_id, :active], name: 'idx_parts_floor_plan_active'
    add_index :parts, :vin, where: "vin IS NOT NULL"
    add_index :parts, :serial_number, where: "serial_number IS NOT NULL"
  end
end
