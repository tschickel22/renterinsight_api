# frozen_string_literal: true

class AddCustomFieldValuesToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :custom_field_values, :jsonb, default: {}, null: false
    add_index :deals, :custom_field_values, using: :gin, name: 'index_deals_on_custom_field_values'
  end
end
