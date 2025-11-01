class CreateCommunicationTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :communication_templates do |t|
      t.string :name, null: false
      t.string :template_type, null: false  # 'company_user_invitation', 'password_reset', etc.
      t.string :channel, null: false        # 'email' or 'sms'
      t.string :subject                     # For email only
      t.text :body, null: false
      t.boolean :is_active, default: true
      t.boolean :is_default, default: false
      t.integer :company_id                 # null = platform-wide template
      t.text :description

      t.timestamps
    end

    add_index :communication_templates, [:template_type, :channel]
    add_index :communication_templates, :company_id
    add_index :communication_templates, :is_active
  end
end
