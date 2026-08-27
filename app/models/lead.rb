# frozen_string_literal: true

class Lead < ApplicationRecord
  include ActivityTrackable
  include Communicable
  include LocationAware
  include NotifiableLead
  include WebhookNotifiable
  include Reportable
  include WorkflowRunCancellable

  def self.reportable_config
    {
      label: "Leads",
      category: "crm",
      fields: [
        { key: "id",         label: "ID",          type: "number",  filterable: true,  sortable: true },
        { key: "first_name", label: "First Name",  type: "string",  filterable: true,  sortable: true },
        { key: "last_name",  label: "Last Name",   type: "string",  filterable: true,  sortable: true },
        { key: "email",      label: "Email",       type: "string",  filterable: true,  sortable: true },
        { key: "phone",      label: "Phone",       type: "string",  filterable: true,  sortable: false },
        { key: "status",     label: "Status",      type: "enum",    filterable: true,  sortable: true },
        { key: "source_id",  label: "Source",      type: "number",  filterable: true,  sortable: true,  resolve_as: :source },
        { key: "owner_id",   label: "Assigned To", type: "number",  filterable: true,  sortable: true,  resolve_as: :user   },
        { key: "created_at", label: "Created At",  type: "date",    filterable: true,  sortable: true },
        { key: "updated_at", label: "Updated At",  type: "date",    filterable: true,  sortable: true }
      ]
    }
  end

  # Transient flag — set to true to suppress assignment notifications (e.g. bulk edits)
  attr_accessor :skip_notifications
  
  belongs_to :company

  # ── Duplicate merge ───────────────────────────────────────────────────────
  # merged_into_id is set when this record lost a merge. It keeps the row
  # intact and pointing at its survivor, so the merge is auditable, reversible
  # and old links can be redirected. Every list query must exclude these.
  belongs_to :merged_into, class_name: 'Lead', optional: true
  belongs_to :merged_by,   class_name: 'User', optional: true

  scope :not_merged, -> { where(merged_into_id: nil) }
  scope :merged_away, -> { where.not(merged_into_id: nil) }

  def merged? = merged_into_id.present?

  # Follows a chain of merges to the record that is actually live now.
  def surviving_record(depth = 0)
    return self if merged_into_id.blank? || depth > 10

    merged_into&.surviving_record(depth + 1) || self
  end
  belongs_to :location, optional: true
  belongs_to :converted_account, class_name: "Account", optional: true
  belongs_to :source, class_name: "Source", optional: true
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  belongs_to :vehicle, optional: true
  belongs_to :preferred_vehicle, class_name: 'Vehicle', foreign_key: 'vehicle_id', optional: true
  belongs_to :social_post, optional: true

  # Core CRM associations
  has_many :activities,           dependent: :destroy
  has_many :reminders,            dependent: :destroy
  has_many :lead_activities,      dependent: :destroy
  has_many :lead_scores,          dependent: :destroy
  has_many :ai_insights,          dependent: :destroy
  has_many :nurture_enrollments, as: :enrollable, dependent: :destroy
  has_many :tracked_links, as: :entity, dependent: :destroy

  # Both of these have a foreign key to leads with no ON DELETE behaviour, so
  # without a dependent option here the database refuses the delete and the
  # request dies as a 500 PG::ForeignKeyViolation. That is what made a lead
  # created from an intake form undeletable.
  #
  # nullify, not destroy, for submissions: the submission is the record of what
  # the visitor actually sent us. It outlives the lead we happened to make from
  # it, and lead_id is nullable precisely because a submission exists before any
  # lead does. A task about a deleted lead has nothing to point at, and its
  # lead_id is NOT NULL, so it goes.
  has_many :intake_submissions, dependent: :nullify
  has_many :lead_tasks,         dependent: :destroy

  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments

  # Owner helper methods
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end

  # Lifecycle webhook for lead conversion
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_is_converted?

  # Workflow engine emit hooks
  after_commit :emit_workflow_created, on: :create
  after_commit :emit_workflow_updated, on: :update
  after_commit :emit_workflow_deleted, on: :destroy

  # Bump last_activity_at whenever the lead is edited. LeadActivity already
  # bumps it via update_columns when an activity is logged (call/email/etc.) —
  # update_columns skips this callback so we don't double-set in that path.
  # Internal/system updates that should NOT count (e.g. score recompute jobs)
  # should also use update_columns.
  before_save :touch_last_activity_at
  before_save :clear_email_invalid_on_address_change

  # Scopes for filtering converted leads
  scope :active, -> { where(is_converted: [false, nil]) }
  scope :converted, -> { where(is_converted: true) }
  scope :not_converted, -> { where(is_converted: [false, nil]) }

  # Helper method for full name
  def full_name
    if first_name.present? || last_name.present?
      "#{first_name} #{last_name}".strip
    elsif name.present?
      name
    else
      email || "Lead ##{id}"
    end
  end

  # Instance methods for conversion
  def converted?
    is_converted == true
  end

  def can_convert?
    !converted? && email.present?
  end

  private

  # email_invalid describes ONE address, so it has to be released when that address is
  # replaced. Without this, correcting a typo left the record permanently unmailable: the
  # flag stayed set against an address that no longer existed on the record, and the fix a
  # rep just made would have looked like it did nothing.
  # Guarded on persisted? because a create "changes" email from nil, which would wipe the
  # flag on any record deliberately imported as already-bad.
  def clear_email_invalid_on_address_change
    self.email_invalid = false if persisted? && will_save_change_to_email?
  end

  def touch_last_activity_at
    # On create: stamp it so new leads have a non-null sortable value.
    # On update: only bump if a tracked attribute actually changed — skip
    # otherwise so re-saving the same record doesn't fake activity.
    return if persisted? && (changes.keys - %w[last_activity_at updated_at]).empty?

    self.last_activity_at = Time.current
  end

  def emit_workflow_created
    WorkflowEngine.emit('lead.created', self, { id: id })
  end

  def emit_workflow_updated
    changes = saved_changes.keys
    # No-op saves (touch on a record already in memory with no attr changes,
    # or a wrapper that resets saved_changes before the callback runs) shouldn't
    # fan out workflow events — staging rule 63 saw 289 empty-changes emissions.
    return if changes.blank?
    WorkflowEngine.emit('lead.updated', self, { id: id, changes: changes })
    if saved_change_to_attribute?(:status)
      from, to = saved_change_to_attribute(:status)
      WorkflowEngine.emit('lead.status_changed', self, { id: id, from: from, to: to })
    end
  end

  def emit_workflow_deleted
    WorkflowEngine.emit('lead.deleted', self, { id: id })
  end

  # Fire lead.converted lifecycle webhook when is_converted changes to true
  # WebhookNotifiable handles generic lead.created/updated/deleted
  def fire_lifecycle_webhooks
    return unless is_converted == true

    WebhookService.fire(
      company_id: company_id,
      event: 'lead.converted',
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Lead] Failed to fire lifecycle webhook lead.converted: #{e.message}"
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:full_name).presence || "#{first_name} #{last_name}".strip.presence || "Lead ##{id}"
  end

  def activity_module_name
    'crm'
  end

  def activity_account_id
    converted_account_id
  end
end
