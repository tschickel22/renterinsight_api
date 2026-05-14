class AddLocationIdToDrawScheduleTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :draw_schedule_templates, :location_id, :integer
    add_index :draw_schedule_templates, [:company_id, :location_id, :is_default],
              name: 'idx_draw_templates_company_location_default'
  end
end
