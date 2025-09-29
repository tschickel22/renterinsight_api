class CreateLeadTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :lead_tasks do |t|
      t.references :lead, null: false, foreign_key: true
      t.string :title
      t.datetime :due_at
      t.boolean :done

      t.timestamps
    end
  end
end
