# frozen_string_literal: true

# Copies a task ticked off on an installer's linked job to the dealer's task
# it came from (E68).
class ProjectLinkTaskSyncJob < ApplicationJob
  queue_as :default

  def perform(task_id)
    ProjectLinkSync.task(ProjectPhaseTask.find_by(id: task_id))
  end
end
