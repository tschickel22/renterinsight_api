# frozen_string_literal: true

module McpTools
  # Same as adding a task on the project in the app
  # (ProjectTasksController#create): a pending task in one of its phases.
  class CreateProjectTask < Base
    tool_name 'create_project_task'
    title 'Add a project task'
    description 'Add a task to a project, in the given phase or else the current phase, optionally with a due ' \
                'date, assignee (a user id from get_reference_data), priority and description. Nobody is notified.'
    input_schema(
      properties: {
        project_id: { type: 'string', description: 'project:12' },
        title: { type: 'string' },
        phase_id: { type: 'string', description: 'phase:40, from get_project' },
        due_date: { type: 'string', description: 'YYYY-MM-DD' },
        assigned_to_user_id: { type: 'integer' },
        priority: { type: 'string', enum: %w[low medium high urgent] },
        description: { type: 'string' }
      },
      required: %w[project_id title]
    )
    writes!(destructive: false)

    def self.perform(ctx, project_id:, title:, phase_id: nil, due_date: nil, assigned_to_user_id: nil,
                     priority: 'medium', description: nil)
      ProjectSupport.require!(ctx, 'create')
      project = ProjectSupport.find_project(ctx, project_id)
      phase =
        if phase_id.present?
          project.project_phases.find(ProjectSupport.parse_id(phase_id, 'phase'))
        else
          project.current_phase || project.project_phases.where.not(status: ProjectSupport::DONE_PHASE_STATUSES).ordered.first ||
            project.project_phases.ordered.last
        end
      raise UserError, 'That project has no phases to put a task in.' unless phase

      task = phase.tasks.build(
        company: ctx.company, project: project, title: title.to_s.strip.first(255), description: description,
        status: 'pending', priority: priority.presence || 'medium', position: phase.tasks.active.count,
        due_date: ListTool.parse_date(due_date, 'due_date'),
        assigned_to_id: assigned_to_user_id && WriteHelpers.assignable_user!(ctx, assigned_to_user_id).id
      )
      task.save!
      ctx.record_change(action: 'created', record: task, after: UpdateProjectTask.serialize(
        task.attributes.slice(*ProjectArea::TASK_UNDO_FIELDS)
      ))

      Base::Result.new(payload: { created: ProjectSupport.task_summary(ctx, task, project: project, phase_name: phase.name) },
                       count: 1)
    end
  end
end
