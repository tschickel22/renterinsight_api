# frozen_string_literal: true

class Project < ApplicationRecord
  include LocationAware

  STATUSES = %w[active completed on_hold cancelled].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :deal, optional: true
  belongs_to :project_template, optional: true
  belongs_to :vehicle, optional: true
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  belongs_to :created_by, class_name: 'User', foreign_key: 'created_by_id', optional: true

  has_many :project_phases, -> { order(:position) }, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :project_number, uniqueness: { scope: :company_id }, allow_nil: true

  # Scopes
  scope :active_projects, -> { where(status: 'active', is_deleted: [false, nil]) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_owner, ->(user_id) { where(owner_id: user_id) if user_id.present? }
  scope :by_deal, ->(deal_id) { where(deal_id: deal_id) if deal_id.present? }

  # Callbacks
  before_create :generate_project_number
  before_create :generate_client_access_token
  before_create :set_started_at

  # ============================================================================
  # PHASE MANAGEMENT
  # ============================================================================

  # Get the current active phase
  def current_phase
    return nil if current_phase_id.nil?
    project_phases.find_by(id: current_phase_id)
  end

  # Advance to the next phase (mark current complete, start next)
  def advance_phase!(completed_by: nil)
    current = current_phase
    return { error: 'No current phase set' } unless current
    return { error: 'Current phase is already completed' } if current.status == 'completed'

    # Complete the current phase
    current.mark_complete!(completed_by: completed_by)

    # Find the next phase
    next_phase = project_phases.where('position > ?', current.position)
                               .where.not(status: 'skipped')
                               .order(:position)
                               .first

    if next_phase
      next_phase.mark_in_progress!
      self.current_phase_id = next_phase.id
    else
      # All phases done — project is complete
      self.status = 'completed'
      self.actual_completion_date = Date.current
      self.current_phase_id = nil
    end

    update_progress_cache!
    save!

    { success: true, completed_phase: current, next_phase: next_phase }
  end

  # Set a specific phase to a given status (manual control)
  def set_phase_status!(phase, new_status, changed_by: nil)
    return { error: 'Phase not found in this project' } unless phase.project_id == id
    return { error: 'Invalid status' } unless ProjectPhase::STATUSES.include?(new_status)

    old_status = phase.status

    ActiveRecord::Base.transaction do
      case new_status
      when 'completed'
        phase.update!(
          status: 'completed',
          completed_at: Time.current,
          completed_by_id: changed_by&.id,
          started_at: phase.started_at || Time.current
        )
      when 'in_progress'
        phase.update!(
          status: 'in_progress',
          started_at: phase.started_at || Time.current,
          completed_at: nil,
          completed_by_id: nil
        )
      when 'not_started'
        phase.update!(
          status: 'not_started',
          started_at: nil,
          completed_at: nil,
          completed_by_id: nil
        )
      end

      # Recalculate current_phase_id: prefer in_progress, else first not_started
      recalc_current_phase!

      # If all phases done, mark project complete
      remaining = project_phases.where.not(status: %w[completed skipped]).count
      if remaining == 0
        self.status = 'completed'
        self.actual_completion_date = Date.current
      elsif status == 'completed'
        self.status = 'active'
        self.actual_completion_date = nil
      end

      update_progress_cache!
      save!
    end

    { success: true, phase: phase.reload, old_status: old_status }
  end

  # Recalculate current_phase_id based on phase statuses
  def recalc_current_phase!
    in_progress = project_phases.find_by(status: 'in_progress')
    if in_progress
      self.current_phase_id = in_progress.id
    else
      first_pending = project_phases.where(status: 'not_started').order(:position).first
      self.current_phase_id = first_pending&.id
    end
  end

  # Undo the last phase advancement (revert most recently completed phase)
  def undo_last_advance!(undone_by: nil)
    phases = project_phases.order(:position)

    # Find the most recently completed phase
    last_completed = phases.where(status: 'completed').order(completed_at: :desc).first
    return { error: 'No completed phases to undo' } unless last_completed

    # Find the current in-progress phase (the one that was started after the completion)
    current_in_progress = phases.find_by(status: 'in_progress')

    ActiveRecord::Base.transaction do
      # Reset the current in-progress phase back to not_started (if there is one)
      if current_in_progress
        current_in_progress.update!(
          status: 'not_started',
          started_at: nil
        )
      end

      # Revert the last completed phase back to in_progress
      last_completed.update!(
        status: 'in_progress',
        completed_at: nil,
        completed_by_id: nil
      )

      # Restore project status if it was marked completed
      if status == 'completed'
        self.status = 'active'
        self.actual_completion_date = nil
      end

      self.current_phase_id = last_completed.id
      update_progress_cache!
      save!
    end

    { success: true, restored_phase: last_completed, reverted_phase: current_in_progress }
  end

  # Skip a phase (mark as skipped, don't advance)
  def skip_phase!(phase, skipped_by: nil)
    return { error: 'Phase not found in this project' } unless phase.project_id == id
    return { error: 'Cannot skip a required phase' } if phase.is_required?
    return { error: 'Phase is already completed' } if phase.status == 'completed'

    phase.update!(
      status: 'skipped',
      completed_by_id: skipped_by&.id,
      completed_at: Time.current
    )

    # If the skipped phase was the current phase, advance to next
    if current_phase_id == phase.id
      next_phase = project_phases.where('position > ?', phase.position)
                                 .where.not(status: 'skipped')
                                 .order(:position)
                                 .first
      if next_phase
        next_phase.mark_in_progress!
        update!(current_phase_id: next_phase.id)
      else
        update!(status: 'completed', actual_completion_date: Date.current, current_phase_id: nil)
      end
    end

    update_progress_cache!
    { success: true, skipped_phase: phase }
  end

  # Recalculate cached progress fields
  def update_progress_cache!
    phases = project_phases.reload
    total = phases.count
    completed = phases.where(status: %w[completed skipped]).count
    pct = total > 0 ? ((completed.to_f / total) * 100).round : 0

    # Set current phase if not set
    current = phases.find_by(status: 'in_progress') || phases.where(status: 'not_started').order(:position).first

    update_columns(
      phase_count: total,
      completed_phase_count: completed,
      progress_percent: pct,
      current_phase_id: current&.id
    )
  end

  # Start the project (set first phase to in_progress)
  def start!
    first_phase = project_phases.order(:position).first
    return unless first_phase && first_phase.status == 'not_started'

    first_phase.mark_in_progress!
    update!(current_phase_id: first_phase.id, started_at: Date.current)
    update_progress_cache!
  end

  # ============================================================================
  # DISPLAY HELPERS
  # ============================================================================

  def current_phase_name
    current_phase&.name || (status == 'completed' ? 'Completed' : 'Not Started')
  end

  def progress_display
    "#{completed_phase_count}/#{phase_count}"
  end

  def customer_display_name
    customer_name.presence || deal&.customer_display_name || 'Unknown'
  end

  def home_display_name
    parts = [home_make, home_model].compact.reject(&:blank?)
    parts.any? ? parts.join(' ') : vehicle&.display_name
  end

  def delivery_address_display
    parts = [delivery_street, delivery_city, delivery_state, delivery_zip].compact.reject(&:blank?)
    parts.join(', ')
  end

  private

  # Auto-generate unique project number per company: P-000001
  def generate_project_number
    return if project_number.present?

    last_num = 0
    if company_id.present?
      result = self.class.connection.select_value(
        "SELECT MAX(CAST(SUBSTRING(project_number FROM 3) AS INTEGER)) FROM projects " \
        "WHERE company_id = #{company_id} AND project_number ~ '^P-[0-9]+$'"
      )
      last_num = result.to_i
    end

    self.project_number = "P-#{(last_num + 1).to_s.rjust(6, '0')}"
  end

  def generate_client_access_token
    return if client_access_token.present?
    self.client_access_token = SecureRandom.urlsafe_base64(32)
  end

  def set_started_at
    self.started_at ||= Date.current
  end
end
