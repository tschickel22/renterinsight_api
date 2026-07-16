# frozen_string_literal: true

# EmitsWorkflowActivityEvents
#
# Include this in LeadActivity / AccountActivity / ContactActivity /
# DealActivity to emit workflow events on the *parent* entity when a child
# activity is created, updated, or completed. Workflows still bind to lead
# / account / contact / deal — the activity travels along inside the event
# payload so templates can reference `{{activity.due_date}}`, `{{activity.subject}}`,
# etc. This is what makes "when a lead has a new activity with a due date,
# set the lead's Next Appointment" expressible without needing a
# `lead_activity` entity type in the rule builder.
module EmitsWorkflowActivityEvents
  extend ActiveSupport::Concern

  # Override in the including class if the parent association isn't named
  # after the child prefix (e.g. LeadActivity → :lead). Concern subclasses
  # commonly override via `workflow_parent :lead` in the class body.
  class_methods do
    def workflow_parent(assoc)
      @workflow_parent_assoc = assoc
    end

    def workflow_parent_assoc
      @workflow_parent_assoc
    end

    def workflow_event_prefix
      # 'LeadActivity' → 'lead_activity'
      name.underscore
    end
  end

  included do
    after_commit :emit_workflow_activity_created, on: :create
    after_commit :emit_workflow_activity_updated, on: :update
    after_commit :emit_workflow_activity_completed_if_needed, on: :update
  end

  private

  def emit_workflow_activity_created
    emit_activity_event('created')
  end

  def emit_workflow_activity_updated
    emit_activity_event('updated', changes: saved_changes.keys)
  end

  # Distinct signal so builders don't have to filter on "status changed to
  # completed" — a very common pattern.
  def emit_workflow_activity_completed_if_needed
    return unless saved_change_to_status? && status == 'completed'
    emit_activity_event('completed')
  end

  def emit_activity_event(verb, extra_payload = {})
    return unless defined?(WorkflowEngine)
    parent = resolve_workflow_parent
    return unless parent

    event_type = "#{self.class.workflow_event_prefix}.#{verb}"
    payload = {
      id: id,
      activity: activity_snapshot_for_workflow
    }.merge(extra_payload)

    WorkflowEngine.emit(event_type, parent, payload)
  rescue => e
    Rails.logger.error "[EmitsWorkflowActivityEvents] #{self.class.name}##{id} #{verb} failed: #{e.message}"
  end

  def resolve_workflow_parent
    assoc = self.class.workflow_parent_assoc
    return nil if assoc.nil?
    public_send(assoc)
  end

  # Only expose the subset builders will realistically bind to. Full
  # as_json can leak internal fields into rule variables and grows the
  # payload every time we add columns. Kept in stringified form because
  # WorkflowEngine.emit persists the payload as JSONB.
  def activity_snapshot_for_workflow
    {
      'id' => id,
      'activity_type' => try(:activity_type),
      'subject' => try(:subject),
      'description' => try(:description),
      'status' => try(:status),
      'priority' => try(:priority),
      'due_date' => try(:due_date)&.iso8601,
      'start_time' => try(:start_time)&.iso8601,
      'end_time' => try(:end_time)&.iso8601,
      'reminder_time' => try(:reminder_time)&.iso8601,
      'completed_at' => try(:completed_at)&.iso8601,
      'assigned_to_id' => try(:assigned_to_id),
      'outcome_notes' => try(:outcome_notes)
    }.compact
  end
end
