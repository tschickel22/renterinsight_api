class AddTaxTimingToDrawScheduleTemplates < ActiveRecord::Migration[8.0]
  def change
    # Column already added manually — this migration is a no-op
    # add_column :draw_schedule_templates, :tax_timing, :string, default: 'per_draw', null: false
  end
end
