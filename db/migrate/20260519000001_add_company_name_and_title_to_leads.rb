# frozen_string_literal: true

class AddCompanyNameAndTitleToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :company_name, :string
    add_column :leads, :title, :string
    add_index :leads, :company_name
  end
end
