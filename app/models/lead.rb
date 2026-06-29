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
        { key: "source_id",  label: "Source",      type: "number",  filterable: true,  sortable: true },
        { key: "owner_id",   label: "Assigned To", type: "number",  filterable: true,  sortable: true },
        { key: "created_at", label: "Created At",  type: "date",    filterable: true,  sortable: true },
        { key: "updated_at", label: "Updated At",  type: "date",    filterable: true,  sortable: true }
      ]
    }
  end

  # Transient flag — set to true to suppress assignment notifications (e.g. bulk edits)
  attr_accessor :skip_notifications
  
  belongs_to :company
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
    WorkflowEngine.emit('lead.updated', self, { id: id, changes: saved_changes.keys })
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
