# frozen_string_literal: true

class AddCustomFieldValuesToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :custom_field_values, :jsonb, null: false, default: {}
  end
end
