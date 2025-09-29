class CreateLeads < ActiveRecord::Migration[8.0]
  def change
    create_table :leads do |t|
      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      t.text :notes
      t.references :source, null: false, foreign_key: true

      t.timestamps
    end
  end
end
