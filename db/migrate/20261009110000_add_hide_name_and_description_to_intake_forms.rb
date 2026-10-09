class AddHideNameAndDescriptionToIntakeForms < ActiveRecord::Migration[8.0]
  # A form placed on a website usually sits under the page's own heading, so
  # its name and description can be switched off where visitors see it.
  def change
    add_column :intake_forms, :hide_name, :boolean, default: false, null: false
    add_column :intake_forms, :hide_description, :boolean, default: false, null: false
  end
end
