# frozen_string_literal: true

# Sends a single batched "new assignments" email to a contractor covering
# all unsent assignments. Enqueued with a short delay (default 10 minutes)
# so multiple rapid assignments are consolidated into one email, and
# accidental assignments can be corrected before the contractor is notified.
#
# This job is a thin wrapper around
# ProjectNotificationService.dispatch_pending_assignments_for_contractor,
# which is also callable inline from the flush endpoint.
class ContractorAssignmentNotifierJob < ApplicationJob
  queue_as :default

  def perform(contractor_id)
    ProjectNotificationService.dispatch_pending_assignments_for_contractor(contractor_id)
  end
end
