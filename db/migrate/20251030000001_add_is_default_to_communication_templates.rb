# frozen_string_literal: true

class AddIsDefaultToCommunicationTemplates < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:communication_templates, :is_default)
      add_column :communication_templates, :is_default, :boolean, default: false
    end
  end
end
