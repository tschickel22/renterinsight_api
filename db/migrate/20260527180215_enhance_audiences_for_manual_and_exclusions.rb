class EnhanceAudiencesForManualAndExclusions < ActiveRecord::Migration[8.0]
  def change
    add_column :audiences, :manual_include_ids, :jsonb, default: []
    add_column :audiences, :manual_exclude_ids, :jsonb, default: []
    add_column :audiences, :exclude_active_campaign_enrollees, :boolean, default: false, null: false
    add_column :audiences, :exclude_active_nurture_enrollees, :boolean, default: false, null: false
  end
end
