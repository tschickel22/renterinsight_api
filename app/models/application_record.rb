class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Per-instance flags that side-effect concerns (NotifiableX, WebhookNotifiable,
  # ActivityTrackable, WorkflowRunCancellable) check before firing their callbacks.
  # Set these to true on records being written by bulk importers / migrations to
  # suppress notifications, webhooks, per-row activity logs, and workflow side
  # effects. Per-instance only — flags don't persist or affect other instances.
  attr_accessor :skip_notifications, :skip_webhooks, :skip_activity_tracking, :skip_workflows
end
