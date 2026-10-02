# frozen_string_literal: true

module McpTools
  # Mirrors the app's own paths: ProjectTasksController#update_status for a
  # project task (with its completion notice), and the phase checklist toggle
  # for a phase step (which starts a phase that had not started yet). Those
  # can email the customer, so the tool works that out first and stops until
  # the person has said yes.
  class UpdateProjectTask < Base
    tool_name 'update_project_task'
    title 'Update a project task or step'
    description 'Change a project task (project_task:N) or a phase checklist step (phase_step:N): status, due ' \
                'date, assignee, and for project tasks actual hours. Completing work can notify people: a ' \
                'completed project task notifies whoever the project is set to notify, and checking off the first ' \
                'step of a phase that has not started starts that phase, which can EMAIL THE CUSTOMER. If a ' \
                'customer would be notified the tool stops and says so; confirm with the user, then call again ' \
                'with customer_notification_ok=true. Customer emails cannot be recalled.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'project_task:5 or phase_step:9' },
        status: { type: 'string', enum: ProjectSupport::TASK_STATUSES,
                  description: 'Phase steps take only pending or completed' },
        due_date: { type: 'string', description: 'YYYY-MM-DD' },
        assigned_to_user_id: { type: 'integer' },
        actual_hours: { type: 'number', minimum: 0, description: 'Project tasks only' },
        customer_notification_ok: { type: 'boolean', description: 'The user agreed the customer may be notified' }
      },
      required: ['id']
    )
    writes!(destructive: true)

    def self.perform(ctx, id:, status: nil, due_date: nil, assigned_to_user_id: nil, actual_hours: nil,
                     customer_notification_ok: false)
      kind, record_id = ProjectSupport.parse_id(id, 'project_task', 'phase_step')
      if [status, due_date, assigned_to_user_id, actual_hours].all?(&:nil?)
        raise UserError, 'Nothing to change: give a status, due_date, assigned_to_user_id or actual_hours.'
      end

      due = ListTool.parse_date(due_date, 'due_date')
      assignee = assigned_to_user_id && WriteHelpers.assignable_user!(ctx, assigned_to_user_id)
      if kind == 'project_task'
        update_task(ctx, record_id, status, due, assignee, actual_hours, customer_notification_ok)
      else
        raise UserError, 'Phase steps have no hours; only project tasks do.' unless actual_hours.nil?

        update_step(ctx, record_id, status, due, assignee, customer_notification_ok)
      end
    end

    def self.update_task(ctx, record_id, status, due, assignee, hours, notification_ok)
      ProjectSupport.require!(ctx, 'update')
      projects = ProjectSupport.projects(ctx)
      task = ProjectTask.active.where(project_id: projects.select(:id)).find(record_id)
      project = task.project

      changes = {}
      changes[:due_date] = due if due
      changes[:assigned_to_id] = assignee.id if assignee
      changes[:actual_hours] = hours unless hours.nil?
      notified = { customer: false, team: false }
      if status && status != task.status
        raise UserError, "Status must be one of #{ProjectSupport::TASK_STATUSES.join(', ')}." unless ProjectSupport::TASK_STATUSES.include?(status)
        if status == 'in_progress' && task.blocked?
          raise UserError, "That task is blocked by: #{task.blocking_tasks.map(&:title).join(', ')}."
        end

        changes[:status] = status
        changes[:started_at] = Date.current if status == 'in_progress' && task.started_at.nil?
        changes[:completed_at] = Date.current if status == 'completed'
        if status == 'completed'
          notified = ProjectSupport.notification_recipients(project, 'task_completed')
          customer_check!(notified, notification_ok, 'Completing this task notifies the customer')
        end
      end

      fields = changes.keys.map(&:to_s)
      before = task.attributes.slice(*fields)
      task.update!(changes)
      ProjectNotificationService.notify_task_completed(task) if changes[:status] == 'completed'
      ctx.record_change(action: 'updated', record: task, before: serialize(before).merge('_customer_notified' => notified[:customer]),
                        after: serialize(task.attributes.slice(*fields)))

      Base::Result.new(payload: {
        updated: ProjectSupport.task_summary(ctx, task.reload, project: project, phase_name: task.project_phase&.name),
        project_progress_percent: project.reload.progress_percent,
        notified: notified
      }, count: 1)
    end

    def self.update_step(ctx, record_id, status, due, assignee, notification_ok)
      ProjectSupport.require!(ctx, 'read')
      ctx.authorize!('deals', 'update') # the app's checklist endpoints gate on deals
      projects = ProjectSupport.projects(ctx)
      step = ProjectPhaseTask.joins(:project_phase).where(project_phases: { project_id: projects.select(:id) }).find(record_id)
      phase = step.project_phase
      project = phase.project
      if status && !ProjectPhaseTask::STATUSES.include?(status)
        raise UserError, 'Phase steps are either pending or completed.'
      end

      changes = {}
      changes[:estimated_completion_date] = due if due
      changes[:assigned_to_id] = assignee.id if assignee
      starts_phase = status == 'completed' && step.status != 'completed' && phase.status == 'not_started'
      notified = { customer: false, team: false }
      if starts_phase
        notified = ProjectSupport.notification_recipients(project, 'phase_started', phase: phase)
        customer_check!(notified, notification_ok,
                        "Checking this off starts the \"#{phase.name}\" phase, which emails the customer")
      end

      before = step.attributes.slice('status', *changes.keys.map(&:to_s))
      ProjectPhaseTask.transaction do
        step.update!(changes) if changes.any?
        if status == 'completed' && step.status != 'completed'
          step.complete!(by: ctx.user)
          if phase.status == 'not_started'
            phase.update!(status: 'in_progress', started_at: phase.started_at || Time.current)
            project.recalc_current_phase!
            project.update_progress_cache!
            project.save!
          end
        elsif status == 'pending' && step.status == 'completed'
          step.reopen!
        end
      end
      after = step.reload.attributes.slice(*before.keys)
      ctx.record_change(action: 'updated', record: step,
                        before: serialize(before).merge('_customer_notified' => notified[:customer], '_started_phase' => starts_phase),
                        after: serialize(after))

      Base::Result.new(payload: {
        updated: ProjectSupport.step_summary(ctx, step, phase.reload, project: project),
        phase_status: phase.status, phase_started: starts_phase,
        project_progress_percent: project.reload.progress_percent,
        notified: notified
      }, count: 1)
    end

    def self.customer_check!(notified, ok, what)
      return unless notified[:customer] && !ok

      raise UserError, "#{what}. Nothing was changed. Tell the user, and if they agree, call again with " \
                       'customer_notification_ok=true.'
    end

    def self.serialize(attrs)
      attrs.transform_values { |v| v.respond_to?(:iso8601) ? v.iso8601 : (v.is_a?(BigDecimal) ? v.to_f : v) }
    end
  end
end
