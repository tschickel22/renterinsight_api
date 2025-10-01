class CreateTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :templates do |t|
      t.string  :name,          null: false
      t.string  :template_type, null: false    # 'email' | 'sms'
      t.string  :subject                         # for email
      t.text    :body                            # email body or sms message
      t.boolean :is_active,     null: false, default: true
      t.timestamps
    end
    add_index :templates, [:template_type, :name]
  end
end
