# frozen_string_literal: true

class AddConfiguratorFieldsToManufacturers < ActiveRecord::Migration[8.0]
  def change
    add_column :manufacturers, :code, :string
    add_column :manufacturers, :logo_url, :string
    add_column :manufacturers, :scraper_enabled, :boolean, default: false
    add_column :manufacturers, :scraper_config, :jsonb, default: {}
    add_column :manufacturers, :last_scraped_at, :datetime

    add_index :manufacturers, :code, unique: true, where: "code IS NOT NULL"
    add_index :manufacturers, :scraper_enabled
  end
end
