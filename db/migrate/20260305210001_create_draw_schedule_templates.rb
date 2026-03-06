class CreateDrawScheduleTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :draw_schedule_templates do |t|
      t.bigint :company_id, null: false
      t.string :name, null: false
      t.boolean :is_default, default: false
      t.jsonb :draws, default: []
      t.boolean :is_deleted, default: false
      t.timestamps
    end

    add_index :draw_schedule_templates, :company_id
    add_index :draw_schedule_templates, [:company_id, :is_default], name: 'idx_draw_templates_company_default'
  end
end
