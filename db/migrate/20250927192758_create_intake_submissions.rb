class CreateIntakeSubmissions < ActiveRecord::Migration[8.0]
  def change
    create_table :intake_submissions do |t|
      t.integer :intake_form_id
      t.json :data
      t.string :status

      t.timestamps
    end
  end
end
