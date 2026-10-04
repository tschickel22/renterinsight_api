# frozen_string_literal: true

# A factory run can wait for a start time and draw through Gemini's batch
# mode (half price, results within hours) instead of one call per drawing.
class AddScheduleToTruebuildFactoryRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :truebuild_factory_runs, :mode, :string, null: false, default: 'now'
    add_column :truebuild_factory_runs, :scheduled_at, :datetime
    add_index :truebuild_factory_runs, %i[status scheduled_at]
  end
end
