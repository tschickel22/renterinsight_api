# frozen_string_literal: true

class AddVisibilityToCustomFields < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:custom_fields, :visibility)
      add_column :custom_fields, :visibility, :string, default: 'both', null: false
    end
  end
end
