# frozen_string_literal: true

class AddShowPriceInMarketingToPackageTemplates < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:package_templates, :show_price_in_marketing)
      add_column :package_templates, :show_price_in_marketing, :boolean, default: true
    end
  end
end
