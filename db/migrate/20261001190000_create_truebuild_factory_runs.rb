# frozen_string_literal: true

# A platform admin's run drawing every price book finish on every model of a
# factory (or one series) ahead of buyers. Platform data, like the catalog.
class CreateTruebuildFactoryRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :truebuild_factory_runs do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.bigint :factory_id
      t.string :series
      t.string :status, null: false, default: 'running'
      t.decimal :budget_usd, precision: 10, scale: 2, null: false
      t.jsonb :variant_ids, null: false, default: []
      t.jsonb :estimate, null: false, default: {}
      t.jsonb :progress, null: false, default: {}
      t.bigint :created_by_id
      t.datetime :stopped_at
      t.timestamps
    end
  end
end
