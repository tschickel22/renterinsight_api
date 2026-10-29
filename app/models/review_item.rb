# frozen_string_literal: true

# Something on a project waiting on a dealer or installer (E87). Review Updates
# lists them; the menu badge counts the open ones that need action.
#
# Items are opened and closed by ProjectNotices, never edited by hand: an item
# closes when the record it points at is dealt with (the bill approved, the bid
# awarded, the job accepted), from whatever screen that happened on. FYI items
# (needs_action false) close when someone marks them seen.
class ReviewItem < ApplicationRecord
  # kind => [label for the filter, needs action?]
  KINDS = {
    # Dealer side
    'contractor_invoice'   => ['Contractor invoice', true],
    'bid_received'         => ['Bids to award', true],
    'bid_declined'         => ['Bid declined', false],
    'installer_quote'      => ['Installer quote', true],
    'change_order'         => ['Change order', true],
    'rate_card'            => ['Rate card', true],
    'installer_bill'       => ['Installer bill', true],
    'job_answered'         => ['Job accepted or declined', false],
    'phase_open_tasks'     => ['Phase closed with open tasks', false],
    'link_request'         => ['Link request', true],
    # Installer side
    'job_offered'          => ['Job offered', true],
    'job_taken_back'       => ['Job taken back', false],
    'change_decided'       => ['Change order decided', false],
    'rate_card_decided'    => ['Rate card decided', false],
    'date_changed'         => ['Date changed', false],
    # Either side
    'assigned'             => ['Assigned to you', false]
  }.freeze

  STATUSES = %w[open closed].freeze

  belongs_to :company
  belongs_to :project, optional: true
  belongs_to :project_phase, optional: true
  belongs_to :subject, polymorphic: true
  belongs_to :assigned_user, class_name: 'User', optional: true

  validates :kind, inclusion: { in: KINDS.keys }
  validates :status, inclusion: { in: STATUSES }
  validates :title, presence: true

  scope :open, -> { where(status: 'open') }
  scope :closed, -> { where(status: 'closed') }
  scope :actionable, -> { where(needs_action: true) }
  # Items for this person: assigned to them, or to nobody in particular.
  scope :for_user, ->(user) { where(assigned_user_id: [nil, user.id]) }

  def self.label_for(kind) = KINDS.dig(kind.to_s, 0) || kind.to_s.humanize

  def open? = status == 'open'

  def as_api_json
    {
      id: id,
      kind: kind,
      kindLabel: self.class.label_for(kind),
      needsAction: needs_action,
      status: status,
      title: title,
      detail: detail,
      fromName: from_name,
      link: link,
      projectId: project_id,
      projectName: project&.name,
      phaseId: project_phase_id,
      phaseName: project_phase&.name,
      subjectType: subject_type,
      subjectId: subject_id,
      assignedUserId: assigned_user_id,
      resolution: resolution,
      resolvedByName: resolved_by_name,
      resolvedAt: resolved_at,
      metadata: metadata,
      createdAt: created_at,
      updatedAt: updated_at
    }
  end
end
