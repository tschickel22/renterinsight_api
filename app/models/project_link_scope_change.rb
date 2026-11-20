# frozen_string_literal: true

# A task the dealer added or changed on a phase a linked installer runs, sent
# to the installer (E106). The installer answers with a change order or "no
# charge"; while it waits, that phase can't start on the installer's side.
class ProjectLinkScopeChange < ApplicationRecord
  KINDS = %w[task_added task_changed].freeze
  STATUSES = %w[pending no_charge change_order withdrawn].freeze

  belongs_to :project_link
  belongs_to :dealer_phase, class_name: 'ProjectPhase'
  belongs_to :dealer_task, class_name: 'ProjectPhaseTask', optional: true
  belongs_to :installer_task, class_name: 'ProjectPhaseTask', optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  belongs_to :answered_by, class_name: 'User', optional: true
  belongs_to :link_change, class_name: 'ProjectLinkChange', optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :description, presence: true

  scope :pending, -> { where(status: 'pending') }

  def pending? = status == 'pending'

  def headline
    kind == 'task_added' ? "Added a task to #{dealer_phase.name}" : "Changed a task on #{dealer_phase.name}"
  end
end
