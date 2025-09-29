class CreateNurtureTables < ActiveRecord::Migration[8.0]
  def change
    create_table :nurture_sequences do |t|
      t.string  :name, null: false
      t.boolean :is_active, default: true, null: false
      t.timestamps
    end

    create_table :nurture_steps do |t|
      t.references :nurture_sequence, null: false, foreign_key: true
      t.string  :step_type, null: false # email|sms|wait|call
      t.string  :subject
      t.text    :body
      t.integer :wait_days
      t.integer :position, null: false, default: 1
      t.timestamps
    end
    add_index :nurture_steps, [:nurture_sequence_id, :position]

    create_table :nurture_enrollments do |t|
      t.references :lead, null: false, foreign_key: true
      t.references :nurture_sequence, null: false, foreign_key: true
      t.string  :status, null: false, default: 'idle' # idle|running|paused|completed
      t.integer :current_step_index
      t.timestamps
    end
    add_index :nurture_enrollments, [:lead_id, :nurture_sequence_id], unique: false
  end
end
