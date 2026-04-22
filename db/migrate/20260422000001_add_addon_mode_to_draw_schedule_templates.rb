class AddAddonModeToDrawScheduleTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :draw_schedule_templates, :addon_mode, :string, default: 'included', null: false
  end
end
