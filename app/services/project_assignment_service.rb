# frozen_string_literal: true

# Whole-project and whole-phase assignment (E69).
#
# A project or phase can have a contractor (assigned_vendor_id) and an employee
# (assigned_to_id). The work itself still happens task by task: a contractor's
# tasks are ContractorAssignment rows on ProjectPhaseTask, which is what the
# contractor portal, review and notifications already run on. Assigning a phase
# hands its unstarted tasks to the new owner.
#
# A task follows its phase only while it is still following it: no contractor
# yet, or the phase's previous contractor. A task someone gave to a different
# contractor on purpose keeps that contractor. Employees work the same way.
class ProjectAssignmentService
  Result = Struct.new(:tasks_updated, :tasks_kept, :tasks_started, :phases_updated, keyword_init: true) do
    def as_json(*)
      { tasksUpdated: tasks_updated, tasksKept: tasks_kept, tasksStarted: tasks_started, phasesUpdated: phases_updated }
    end
  end

  # Assignments past this point mean the contractor has started the task.
  STARTED_ASSIGNMENT_STATUSES = %w[accepted in_progress completed].freeze

  def initialize(project, actor:)
    @project = project
    @company = project.company
    @actor = actor
    @owner_notices = []
    @user_notices = []
    @task_assigned_vendor_ids = Set.new
  end

  # changes: { vendor: Contractor|nil, user: User|nil }; a key that is absent is left alone.
  # preview: run everything, report the counts, write nothing (and notify no one).
  def assign_phase(phase, changes, apply_to_tasks:, preview: false)
    run(preview) do |result|
      assign_phase!(phase, changes, apply_to_tasks, result)
    end
  end

  # apply_to_phases: phases still following the project (no owner, or the
  # project's previous owner) take the new owner, and so do their unstarted tasks.
  def assign_project(changes, apply_to_phases:, preview: false)
    run(preview) do |result|
      old_vendor_id = @project.assigned_vendor_id
      old_user_id = @project.assigned_to_id
      attrs = {}
      attrs[:assigned_vendor_id] = changes[:vendor]&.id if changes.key?(:vendor)
      attrs[:assigned_to_id] = changes[:user]&.id if changes.key?(:user)
      @project.update!(attrs) if attrs.any?
      note_owner(changes[:vendor], old_vendor_id, nil)
      note_user(changes[:user], old_user_id, nil) if changes.key?(:user)

      if apply_to_phases
        @project.project_phases.where.not(status: %w[completed skipped]).ordered.each do |phase|
          phase_changes = {}
          if changes.key?(:vendor) && phase.assigned_vendor_id.in?([nil, old_vendor_id])
            phase_changes[:vendor] = changes[:vendor]
          end
          if changes.key?(:user) && phase.assigned_to_id.in?([nil, old_user_id])
            phase_changes[:user] = changes[:user]
          end
          next if phase_changes.empty?

          result.phases_updated += 1
          assign_phase!(phase, phase_changes, true, result)
        end
      end
    end
  end

  # A task added to a live phase starts with the phase's owners.
  def inherit_for_new_task!(task)
    phase = task.project_phase
    task.update!(assigned_to_id: phase.assigned_to_id) if task.assigned_to_id.nil? && phase.assigned_to_id
    vendor = phase.assigned_vendor_id && @company.contractors.active.find_by(id: phase.assigned_vendor_id)
    assign_contractor!(task, vendor) if vendor && task.contractor_assignments.none?
  end

  private

  def run(preview)
    result = Result.new(tasks_updated: 0, tasks_kept: 0, tasks_started: 0, phases_updated: 0)
    ActiveRecord::Base.transaction do
      yield result
      # Rolling back also drops the after_commit notifications, so a preview
      # never emails a contractor.
      raise ActiveRecord::Rollback if preview
    end
    unless preview
      send_owner_notices
      ProjectNotices.employee_assigned(@project, @user_notices, actor: @actor)
    end
    result
  end

  # A new project or phase owner hears about it through their task emails. One
  # who got no tasks out of it (a phase with no tasks yet, or tasks all taken)
  # gets one notice per change instead.
  def note_owner(vendor, old_vendor_id, phase)
    return if vendor.nil? || vendor.id == old_vendor_id

    @owner_notices << [vendor, phase]
  end

  # An employee given the project or a phase hears about it (E87): one notice
  # per person listing what they got.
  def note_user(user, old_user_id, phase)
    return if user.nil? || user.id == old_user_id

    @user_notices << [user, phase]
  end

  def send_owner_notices
    @owner_notices.reject { |vendor, _| @task_assigned_vendor_ids.include?(vendor.id) }
                  .uniq { |vendor, _| vendor.id }
                  .each do |vendor, phase|
      ProjectNotificationService.notify_contractor_owner_assigned(vendor, @project, phase: phase)
    end
  end

  def assign_phase!(phase, changes, apply_to_tasks, result)
    old_vendor_id = phase.assigned_vendor_id
    old_user_id = phase.assigned_to_id
    attrs = {}
    attrs[:assigned_vendor_id] = changes[:vendor]&.id if changes.key?(:vendor)
    attrs[:assigned_to_id] = changes[:user]&.id if changes.key?(:user)
    phase.update!(attrs) if attrs.any?
    note_owner(changes[:vendor], old_vendor_id, phase) if changes.key?(:vendor)
    note_user(changes[:user], old_user_id, phase) if changes.key?(:user)
    return unless apply_to_tasks

    phase.project_phase_tasks.includes(:contractor_assignments).each do |task|
      if started?(task)
        result.tasks_started += 1
        next
      end

      changed = false
      kept = false

      if changes.key?(:vendor)
        case apply_contractor(task, old_vendor_id, changes[:vendor])
        when :changed then changed = true
        when :kept then kept = true
        end
      end

      if changes.key?(:user)
        new_user_id = changes[:user]&.id
        if task.assigned_to_id == new_user_id
          # already right
        elsif task.assigned_to_id.in?([nil, old_user_id])
          task.update!(assigned_to_id: new_user_id)
          sync_rich_task_user(phase, task, old_user_id, new_user_id)
          changed = true
        else
          kept = true
        end
      end

      if changed
        result.tasks_updated += 1
      elsif kept
        result.tasks_kept += 1
      end
    end
  end

  # :changed, :kept (another contractor was put on it on purpose) or :same.
  def apply_contractor(task, old_vendor_id, new_vendor)
    assignments = task.contractor_assignments.to_a
    return :same if new_vendor && assignments.any? { |a| a.vendor_id == new_vendor.id }

    inherited = assignments.select { |a| old_vendor_id && a.vendor_id == old_vendor_id }
    others = assignments - inherited
    return :kept if others.any?
    return :same if inherited.empty? && new_vendor.nil?

    inherited.each(&:destroy!)
    assign_contractor!(task, new_vendor) if new_vendor
    :changed
  end

  def assign_contractor!(task, vendor)
    @task_assigned_vendor_ids << vendor.id
    task.contractor_assignments.create!(
      contractor: vendor,
      company: @company,
      assigned_by: @actor,
      status: 'assigned',
      assigned_at: Time.current
    )
  end

  def started?(task)
    task.status == 'completed' ||
      task.contractor_assignments.any? { |a| a.status.in?(STARTED_ASSIGNMENT_STATUSES) || a.review_status.present? }
  end

  # Template builds make a ProjectTask beside each ProjectPhaseTask with the same
  # title. There is no key between them, so match on phase and title.
  def sync_rich_task_user(phase, task, old_user_id, new_user_id)
    phase.tasks.where(title: task.name, status: 'pending', assigned_to_id: [nil, old_user_id].uniq)
         .update_all(assigned_to_id: new_user_id, updated_at: Time.current)
  end
end
