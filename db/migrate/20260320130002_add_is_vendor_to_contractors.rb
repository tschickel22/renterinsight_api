# frozen_string_literal: true

class AddIsVendorToContractors < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:contractors, :is_vendor)
      add_column :contractors, :is_vendor, :boolean, default: false
      add_index :contractors, :is_vendor
    end
  end
end
