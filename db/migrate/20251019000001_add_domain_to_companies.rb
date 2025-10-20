# frozen_string_literal: true

class AddDomainToCompanies < ActiveRecord::Migration[7.1]
  def change
    add_column :companies, :domain, :string
    add_index :companies, :domain, unique: true
  end
end
