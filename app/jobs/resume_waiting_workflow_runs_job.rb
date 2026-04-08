class ResumeWaitingWorkflowRunsJob < ApplicationJob
  queue_as :default

  def perform
    WorkflowRun.due_for_resume.find_each do |run|
      WorkflowEngine.resume(run)
    end
  end
end
