# frozen_string_literal: true

class AddDefaultTasksToProjectTemplatePhases < ActiveRecord::Migration[8.0]
  def change
    add_column :project_template_phases, :default_tasks, :jsonb, default: []
  end
end
