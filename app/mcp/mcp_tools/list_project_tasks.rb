# frozen_string_literal: true

module McpTools
  # Work across projects: phase checklist steps and project tasks together,
  # soonest due first. Most steps and tasks have no date (production,
  # 2026-10), so the order of undated work matters as much: phase order, then
  # position within the phase, then id, so the same call lists the same order.
  class ListProjectTasks < ListTool
    tool_name 'list_project_tasks'
    title 'List project tasks and steps'
    description 'Open work across projects: the checklist steps inside each phase (phase_step ids) and project ' \
                'tasks (project_task ids). Ordered by due date, soonest first, with undated work last; ties ' \
                'and undated work follow the phase order, then each phase\'s own step order. A step with no ' \
                'date of its own uses its phase\'s estimated completion date (due_source "phase"). ' \
                'Filters: assigned ("me" or a user id), ' \
                'overdue_only, due_within_days, status (open by default, or completed or any), project.'
    input_schema(
      properties: {
        assigned: { type: 'string', description: '"me" or a user id' },
        overdue_only: { type: 'boolean' },
        due_within_days: { type: 'integer', minimum: 0 },
        status: { type: 'string', enum: %w[open completed any] },
        project_id: { type: 'string', description: 'project:12' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, assigned: nil, overdue_only: false, due_within_days: nil, status: 'open', project_id: nil, limit: 30)
      projects = ProjectSupport.projects(ctx)
      projects = projects.where(id: ProjectSupport.find_project(ctx, project_id).id) if project_id.present?
      project_rows = projects.select(:id, :name).to_a.index_by(&:id)
      cap = ctx.row_limit(limit)
      today = ProjectSupport.today
      user_id = assigned == 'me' ? ctx.user.id : assigned.to_i if assigned.present?
      cutoff = overdue_only ? today - 1 : (today + due_within_days.to_i if due_within_days.present?)

      tasks = ProjectTask.active.where(project_id: project_rows.keys).includes(:project_phase)
      tasks = filter_status(tasks, status, ProjectSupport::OPEN_TASK_STATUSES, %w[completed])
      tasks = tasks.where(assigned_to_id: user_id) if user_id
      tasks = tasks.where('project_tasks.due_date <= ?', cutoff) if cutoff
      tasks = tasks.joins(:project_phase)
                   .order(Arel.sql('project_tasks.due_date ASC NULLS LAST'), 'project_phases.position',
                          'project_tasks.project_id', 'project_tasks.position', 'project_tasks.id')
                   .limit(cap).to_a

      due_sql = 'COALESCE(project_phase_tasks.estimated_completion_date, project_phases.estimated_completion_date)'
      steps = ProjectPhaseTask.joins(:project_phase).includes(:project_phase)
                              .where(project_phases: { project_id: project_rows.keys })
      steps = filter_status(steps, status, %w[pending], %w[completed])
      steps = steps.where.not(project_phases: { status: ProjectSupport::DONE_PHASE_STATUSES }) if status.blank? || status == 'open'
      steps = steps.where(assigned_to_id: user_id) if user_id
      steps = steps.where("#{due_sql} <= ?", cutoff) if cutoff
      steps = steps.order(Arel.sql("#{due_sql} ASC NULLS LAST"), 'project_phases.position', 'project_phases.project_id',
                          'project_phase_tasks.position', 'project_phase_tasks.id')
                   .limit(cap).to_a

      rows = tasks.map do |t|
        [sort_key(t.due_date, t.project_phase&.position, t.project_id, t.position, 1, t.id),
         ProjectSupport.task_summary(ctx, t, project: project_rows[t.project_id], phase_name: t.project_phase&.name)]
      end
      rows += steps.map do |s|
        phase = s.project_phase
        [sort_key(ProjectSupport.step_due(s, phase), phase.position, phase.project_id, s.position, 0, s.id),
         ProjectSupport.step_summary(ctx, s, phase, project: project_rows[phase.project_id])]
      end
      items = rows.sort_by(&:first).first(cap).map(&:last)
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
    end

    # Due date with undated last, then phase order, then project, then the
    # position inside the phase; steps before project tasks on a full tie,
    # and id last so the order never shifts between calls.
    def self.sort_key(due, phase_position, project_id, position, kind_rank, id)
      [due ? 0 : 1, due || Date.new(0), phase_position || 0, project_id, position || 0, kind_rank, id]
    end

    def self.filter_status(relation, status, open, done)
      case status
      when 'any' then relation
      when 'completed' then relation.where(status: done)
      else relation.where(status: open)
      end
    end
  end
end
