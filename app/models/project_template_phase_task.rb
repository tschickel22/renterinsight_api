# frozen_string_literal: true

class ProjectTemplatePhaseTask < ApplicationRecord
  belongs_to :project_template_phase
  belongs_to :default_vendor, class_name: 'Vendor', optional: true
  belongs_to :default_assigned_to, class_name: 'User', optional: true

  validates :name, presence: true
  validates :position, presence: true

  scope :ordered, -> { order(:position) }
end
