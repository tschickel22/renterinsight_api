class CreateSources < ActiveRecord::Migration[8.0]
  def change
    create_table :sources do |t|
      t.string :name
      t.string :source_type
      t.string :tracking_code
      t.boolean :is_active
      t.decimal :conversion_rate

      t.timestamps
    end
  end
end
