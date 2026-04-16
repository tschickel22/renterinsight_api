# frozen_string_literal: true

# Sends a single batched "reviews pending" email to the dealer project owner
# covering all unsent review submissions for a project. Thin wrapper around
# ProjectNotificationService.dispatch_pending_reviews_for_project.
class DealerReviewNotifierJob < ApplicationJob
  queue_as :default

  def perform(project_id)
    ProjectNotificationService.dispatch_pending_reviews_for_project(project_id)
  end
end
