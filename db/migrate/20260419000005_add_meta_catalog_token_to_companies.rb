# frozen_string_literal: true

class AddMetaCatalogTokenToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :meta_catalog_token, :string
  end
end
