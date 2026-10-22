# frozen_string_literal: true

# A handed-off dealer phase and its copy in the installer's project.
class ProjectLinkPhase < ApplicationRecord
  belongs_to :project_link
  belongs_to :dealer_phase, class_name: 'ProjectPhase'
  belongs_to :installer_phase, class_name: 'ProjectPhase', optional: true
end
