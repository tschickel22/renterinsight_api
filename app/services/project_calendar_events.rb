# frozen_string_literal: true

# Project phases and phase tasks on the calendar (E108), as all-day spans
# from their estimated start to their estimated completion. Used by the
# DealerTide calendar (CalendarService) and by a person's private calendar
# link (CalendarFeeds::IcsOut).
#
# Whose work shows:
#   mine  - phases on projects the person owns or runs (owner or assigned
#           person), and any phase or task assigned to them. Tasks on their
#           projects that belong to someone else stay off, so an owner of
#           twenty jobs sees phases, not every step.
#   team  - the same, for every person on the team.
#   all   - every phase and every dated task.
# Cancelled projects and deleted ones never show. A phase or task with only
# one date shows on that day.
class ProjectCalendarEvents
  PHASE_TYPE = 'project_phase'
  TASK_TYPE = 'project_task'
  TYPES = [PHASE_TYPE, TASK_TYPE].freeze
  LIMIT = 2000

  # One color per project, picked by id so it stays the same between loads.
  PALETTE = %w[#0F766E #B45309 #7C3AED #BE123C #1D4ED8 #4D7C0F #A21CAF #0E7490 #C2410C #4338CA].freeze

  def self.color_for(project_id) = PALETTE[project_id.to_i % PALETTE.size]

  # projects: the already scoped Project relation the person may see.
  # user_ids: whose work (nil means everyone).
  def initialize(projects:, user_ids: nil, from: nil, to: nil, types: TYPES)
    @projects = projects.not_deleted.where.not(status: 'cancelled')
    @user_ids = user_ids
    @from = from
    @to = to
    @types = types
  end

  def phases
    return ProjectPhase.none unless @types.include?(PHASE_TYPE)

    scope = ProjectPhase.joins(:project).merge(@projects).includes(:project, :assigned_to)
    scope = dated(scope, 'project_phases')
    if @user_ids
      scope = scope.where('projects.owner_id IN (:ids) OR projects.assigned_to_id IN (:ids) OR project_phases.assigned_to_id IN (:ids)',
                          ids: @user_ids)
    end
    scope.order('project_phases.estimated_start_date').limit(LIMIT)
  end

  def tasks
    return ProjectPhaseTask.none unless @types.include?(TASK_TYPE)

    scope = ProjectPhaseTask.joins(project_phase: :project).merge(@projects).includes({ project_phase: :project }, :assigned_to)
    scope = dated(scope, 'project_phase_tasks')
    scope = scope.where(assigned_to_id: @user_ids) if @user_ids
    scope.order('project_phase_tasks.estimated_start_date').limit(LIMIT)
  end

  # Unified calendar events (CalendarService shape).
  def events
    phases.map { |phase| phase_event(phase) } + tasks.map { |task| task_event(task) }
  end

  # [first_day, last_day] of a phase or task, from whichever dates it has.
  def self.span(record)
    first = record.estimated_start_date || record.estimated_completion_date
    last = record.estimated_completion_date || record.estimated_start_date
    last = first if last < first
    [first, last]
  end

  private

  # Only records with a date that overlap the window.
  def dated(scope, table)
    starts = "COALESCE(#{table}.estimated_start_date, #{table}.estimated_completion_date)"
    ends = "COALESCE(#{table}.estimated_completion_date, #{table}.estimated_start_date)"
    scope = scope.where("#{starts} IS NOT NULL")
    scope = scope.where("GREATEST(#{ends}, #{starts}) >= ?", @from.to_date) if @from
    scope = scope.where("#{starts} <= ?", @to.to_date) if @to
    scope
  end

  def phase_event(phase)
    project = phase.project
    base_event(phase, project, type: PHASE_TYPE, id: "project-phase-#{phase.id}",
                               title: "#{phase.name}: #{project_label(project)}", phase_name: phase.name)
  end

  def task_event(task)
    phase = task.project_phase
    project = phase.project
    base_event(task, project, type: TASK_TYPE, id: "project-task-#{task.id}",
                              title: "#{task.name}: #{project_label(project)}", phase_name: phase.name)
  end

  def project_label(project)
    project.customer_name.presence || project.name
  end

  def base_event(record, project, type:, id:, title:, phase_name:)
    first, last = self.class.span(record)
    person = record.assigned_to
    {
      id: id,
      title: title,
      type: type,
      # All-day: start is the first day, end is the day after the last one.
      start: first.iso8601,
      end: (last + 1).iso8601,
      all_day: true,
      status: record.status,
      priority: nil,
      description: [project.name, phase_name].compact_blank.uniq.join(', '),
      assigned_to: person && { id: person.id, name: person.full_name, email: person.email },
      source: { type: 'project', id: project.id, name: project.name },
      color: self.class.color_for(project.id),
      entity_name: project.name,
      entity_type: 'project',
      entity_id: project.id,
      project_id: project.id,
      location_id: project.location_id
    }
  end
end
