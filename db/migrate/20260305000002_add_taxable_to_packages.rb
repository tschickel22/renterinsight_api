# frozen_string_literal: true

class AddTaxableToPackages < ActiveRecord::Migration[8.0]
  def change
    add_column :inventory_packages, :taxable, :boolean, default: false unless column_exists?(:inventory_packages, :taxable)
    add_column :inventory_packages, :tax_rate, :decimal, precision: 5, scale: 3 unless column_exists?(:inventory_packages, :tax_rate)

    add_column :package_templates, :taxable, :boolean, default: false unless column_exists?(:package_templates, :taxable)
    add_column :package_templates, :tax_rate, :decimal, precision: 5, scale: 3 unless column_exists?(:package_templates, :tax_rate)
  end
end
