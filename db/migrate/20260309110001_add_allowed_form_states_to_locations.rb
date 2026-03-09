class AddAllowedFormStatesToLocations < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:locations, :allowed_form_states)
      add_column :locations, :allowed_form_states, :jsonb, default: [], null: false
    end
  end
end
