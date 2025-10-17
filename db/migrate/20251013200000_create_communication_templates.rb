class CreateCommunicationTemplates < ActiveRecord::Migration[7.0]
  def change
    create_table :communication_templates do |t|
      t.string :name, null: false
      t.string :template_type, null: false # 'email' or 'sms'
      t.string :subject # Only for email
      t.text :body # For email
      t.text :message # For SMS
      t.string :category
      t.json :merge_vars, default: []
      t.boolean :is_active, default: true
      t.text :description
      t.references :company, foreign_key: true, null: true
      
      t.timestamps
    end

    add_index :communication_templates, :template_type
    add_index :communication_templates, :category
    add_index :communication_templates, :is_active
    add_index :communication_templates, :name
  end
end
