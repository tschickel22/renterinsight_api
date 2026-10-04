# frozen_string_literal: true

# The March 2026 home configurator never worked and TrueBuild replaces it.
# Every one of its tables was empty on production and staging (checked
# 2026-09-30), as were vehicles.floor_plan_id and parts.floor_plan_id.
# Those two columns stay for now (ignored by their models): dropping a column
# while older servers still write it breaks inserts mid-deploy.
class DropRetiredConfiguratorTables < ActiveRecord::Migration[8.0]
  TABLES = %w[company_floor_plan_option_overrides floor_plan_option_applicabilities configurations company_floor_plans
              floor_plan_options option_categories floor_plans].freeze

  def up
    remove_foreign_key :vehicles, :floor_plans if foreign_key_exists?(:vehicles, :floor_plans)
    remove_foreign_key :parts, :floor_plans if foreign_key_exists?(:parts, :floor_plans)
    TABLES.each do |table|
      next unless table_exists?(table)

      rows = select_value("SELECT COUNT(*) FROM #{table}").to_i
      raise "#{table} has #{rows} rows; not dropping configurator data" if rows.positive?

      drop_table table, force: :cascade
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
