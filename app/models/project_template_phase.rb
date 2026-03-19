# frozen_string_literal: true

class ProjectTemplatePhase < ApplicationRecord
  belongs_to :project_template, counter_cache: :phase_count
  has_many :project_template_phase_tasks, -> { order(:position) }, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # Scopes
  scope :ordered, -> { order(:position) }
  scope :client_visible, -> { where(visible_to_client: true) }

  # Phase 2A: default_tasks is a JSONB column with rich task blueprints
  # Format: [{ title: "...", description: "...", task_type: "...", position: 0,
  #            estimated_hours: 4, checklist: ["item 1", "item 2"] }]
end
