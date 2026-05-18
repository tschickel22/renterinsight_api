# frozen_string_literal: true

class AddIndustryToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :industry, :string, default: 'manufactured_housing', null: false
    add_index :companies, :industry
  end
end
