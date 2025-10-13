class AddTemplateIdToCommunications < ActiveRecord::Migration[7.0]
  def change
    add_reference :communications, :template, foreign_key: { to_table: :communication_templates }, null: true, index: true
  end
end
