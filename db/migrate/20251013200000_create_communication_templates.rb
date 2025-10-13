class CreateCommunicationTemplates < ActiveRecord::Migration[7.0]
  def change
    create_table :communication_templates do |t|
      t.string :name, null: false
      t.string :channel, null: false # 'email' or 'sms'
      t.text :subject_template # Only for email
      t.text :body_template, null: false
      t.string :category
      t.json :variables, default: '{}'
      t.boolean :active, default: true
      t.text :description
      
      t.timestamps
    end

    add_index :communication_templates, :channel
    add_index :communication_templates, :category
    add_index :communication_templates, :active
    add_index :communication_templates, :name
  end
end
