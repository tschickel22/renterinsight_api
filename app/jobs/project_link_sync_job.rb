# frozen_string_literal: true

# Copies a phase change across a company link (E68 step 5d).
class ProjectLinkSyncJob < ApplicationJob
  queue_as :default

  def perform(phase_id)
    phase = ProjectPhase.find_by(id: phase_id)
    ProjectLinkSync.new(phase).run if phase
  end
end
