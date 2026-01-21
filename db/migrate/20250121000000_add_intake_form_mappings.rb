class AddIntakeFormMappings < ActiveRecord::Migration[8.0]
  def change
    add_reference :intake_forms, :notified_user, foreign_key: { to_table: :users }, null: true
    add_column :intake_forms, :field_mappings, :json, default: {}
    add_column :intake_forms, :auto_create_lead, :boolean, default: true
    add_column :intake_forms, :auto_create_activity, :boolean, default: true
  end
end
