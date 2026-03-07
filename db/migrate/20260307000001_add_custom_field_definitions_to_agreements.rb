class AddCustomFieldDefinitionsToAgreements < ActiveRecord::Migration[8.0]
  def change
    add_column :agreements, :custom_field_definitions, :jsonb, default: []
  end
end
