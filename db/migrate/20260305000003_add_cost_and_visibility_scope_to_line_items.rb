# frozen_string_literal: true

class AddCostAndVisibilityScopeToLineItems < ActiveRecord::Migration[8.0]
  def change
    # Add cost basis to inventory line items
    add_column :inventory_packages, :cost, :decimal, precision: 12, scale: 2 unless column_exists?(:inventory_packages, :cost)

    # Add cost basis and visibility scope to templates
    add_column :package_templates, :cost, :decimal, precision: 12, scale: 2 unless column_exists?(:package_templates, :cost)
    add_column :package_templates, :visibility_scope, :string, default: 'all' unless column_exists?(:package_templates, :visibility_scope)
    # visibility_scope: 'inventory' (hide from deals/invoices/quotes), 'finance' (hide from inventory), 'all' (show everywhere)
  end
end
