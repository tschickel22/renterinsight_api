# frozen_string_literal: true

class ChangeCustomFieldVisibilityDefaultToInternal < ActiveRecord::Migration[8.0]
  def change
    change_column_default :custom_fields, :visibility, from: 'both', to: 'internal'
  end
end
