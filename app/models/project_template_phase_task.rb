# frozen_string_literal: true

class ProjectTemplatePhaseTask < ApplicationRecord
  belongs_to :project_template_phase

  validates :name, presence: true
  validates :position, presence: true

  scope :ordered, -> { order(:position) }
end
