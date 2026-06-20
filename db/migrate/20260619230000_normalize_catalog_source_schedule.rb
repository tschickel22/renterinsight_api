class NormalizeCatalogSourceSchedule < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE catalog_sources
      SET schedule = CASE WHEN LOWER(schedule) = 'nightly' THEN 'daily' ELSE 'weekly' END
      WHERE schedule IS NULL OR LOWER(schedule) NOT IN ('daily', 'weekly', 'manual')
    SQL
    change_column_default :catalog_sources, :schedule, 'weekly'
  end

  def down
    change_column_default :catalog_sources, :schedule, 'nightly'
  end
end
