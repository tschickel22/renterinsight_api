# frozen_string_literal: true

module McpTools
  # Work across projects: phase checklist steps and project tasks together,
  # soonest due first.
  class ListProjectTasks < ListTool
    tool_name 'list_project_tasks'
    title 'List project tasks and steps'
    description 'Open work across projects: the checklist steps inside each phase (phase_step ids) and project ' \
                'tasks (project_task ids), soonest due first. A step with no date of its own uses its phase\'s ' \
                'estimated completion date (due_source "phase"). Filters: assigned ("me" or a user id), ' \
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
      tasks = tasks.order(Arel.sql('project_tasks.due_date ASC NULLS LAST')).limit(cap).to_a

      due_sql = 'COALESCE(project_phase_tasks.estimated_completion_date, project_phases.estimated_completion_date)'
      steps = ProjectPhaseTask.joins(:project_phase).includes(:project_phase)
                              .where(project_phases: { project_id: project_rows.keys })
      steps = filter_status(steps, status, %w[pending], %w[completed])
      steps = steps.where.not(project_phases: { status: ProjectSupport::DONE_PHASE_STATUSES }) if status.blank? || status == 'open'
      steps = steps.where(assigned_to_id: user_id) if user_id
      steps = steps.where("#{due_sql} <= ?", cutoff) if cutoff
      steps = steps.order(Arel.sql("#{due_sql} ASC NULLS LAST"), 'project_phases.position', 'project_phase_tasks.position')
                   .limit(cap).to_a

      items = tasks.map do |t|
        ProjectSupport.task_summary(ctx, t, project: project_rows[t.project_id], phase_name: t.project_phase&.name)
      end
      items += steps.map do |s|
        ProjectSupport.step_summary(ctx, s, s.project_phase, project: project_rows[s.project_phase.project_id])
      end
      items = items.sort_by { |i| i[:due] || '9999' }.first(cap)
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
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
