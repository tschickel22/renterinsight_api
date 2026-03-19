# frozen_string_literal: true

class ProjectPhaseTask < ApplicationRecord
  STATUSES = %w[pending completed].freeze

  belongs_to :project_phase
  belongs_to :company
  belongs_to :completed_by, class_name: 'User', optional: true
  belongs_to :assigned_to, class_name: 'User', optional: true

  # Polymorphic contractor assignments (Phase 2B)
  has_many :contractor_assignments, as: :assignable, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :ordered,           -> { order(:position) }
  scope :pending,           -> { where(status: 'pending') }
  scope :completed,         -> { where(status: 'completed') }
  scope :client_visible,    -> { where(visible_to_client: true) }
  scope :client_actionable, -> { where(client_actionable: true) }

  def complete!(by: nil)
    update!(status: 'completed', completed_at: Time.current, completed_by: by)
  end

  def reopen!
    update!(status: 'pending', completed_at: nil, completed_by: nil)
  end

  def acknowledged?
    client_acknowledged_at.present?
  end
end
