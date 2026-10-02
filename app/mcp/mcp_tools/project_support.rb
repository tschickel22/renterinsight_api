# frozen_string_literal: true

module McpTools
  # Shared by the project tools: plan and permission checks, scoping, and the
  # serializers.
  #
  # Two kinds of work live under a project, and the tools expose both:
  #   phase steps (project_phase_tasks, "phase_step:N") are the checklist inside
  #     each phase that dealers actually tick off in the app. Gated on 'deals'
  #     update, as the app's toggle endpoint is.
  #   project tasks (project_tasks, "project_task:N") carry an assignee, due
  #   date and hours. Gated on 'projects', as ProjectTasksController is.
  # In production (2026-10) dealers work the phase steps; project tasks exist
  # (created from templates) but none has a due date or assignee yet.
  #
  # A phase step rarely has its own dates, so its due date falls back to its
  # phase's estimated completion date and says so (due_source: "phase").
  module ProjectSupport
    MODULE_KEY = 'management.projects'
    OPEN_TASK_STATUSES = %w[pending in_progress blocked].freeze
    TASK_STATUSES = %w[pending in_progress completed blocked skipped].freeze
    DONE_PHASE_STATUSES = %w[completed skipped].freeze

    module_function

    def require!(ctx, action = 'read')
      unless ModuleAccessService.new(ctx.company).has_module?(MODULE_KEY)
        raise Denied, "Project Management is not part of this account's plan, so I cannot read or change projects."
      end

      ctx.authorize!('projects', action)
    end

    # ProjectsController#index: the company's projects that are not deleted,
    # narrowed to the person's locations plus projects with no location.
    def projects(ctx)
      require!(ctx)
      ctx.scope_locations(ctx.company.projects.not_deleted, include_unlocated: true)
    end

    def find_project(ctx, typed_id)
      projects(ctx).find(parse_id(typed_id, 'project'))
    end

    # "project_task:5" -> ["project_task", 5]. Accepts a bare number for the
    # expected kind.
    def parse_id(value, *kinds)
      text = value.to_s.strip
      return text.to_i if text.match?(/\A\d+\z/) && kinds.size == 1

      kind, id = text.split(':', 2)
      unless kinds.include?(kind) && id.to_s.match?(/\A\d+\z/)
        raise UserError, "Ids look like #{kinds.map { |k| "#{k}:12" }.join(' or ')}, not #{value.inspect}."
      end

      kinds.size == 1 ? id.to_i : [kind, id.to_i]
    end

    # Internal job costs show only where dealer cost is allowed through the
    # connector. In the app the Costs & Budget tab is open to anyone who can
    # read projects; the connector adds the dealer's "AI apps can see dealer
    # cost" switch on top, as it does for deals and inventory.
    def costs_visible?(ctx)
      ctx.show_costs? && ctx.can?('projects', 'read')
    end

    # Projects have no page of their own: they open from their deal, or from
    # the projects list.
    def url(ctx, project)
      project.deal_id ? ctx.app_url("/deals/#{project.deal_id}") : ctx.app_url('/deals/projects')
    end

    def today
      Date.current
    end

    # SQL for a phase's effective due date: its steps' latest estimated date,
    # else its own (ProjectPhase#computed_completion_date).
    PHASE_DUE_SQL = 'COALESCE((SELECT MAX(s.estimated_completion_date) FROM project_phase_tasks s ' \
                    'WHERE s.project_phase_id = project_phases.id), project_phases.estimated_completion_date)'

    def behind_schedule_ids(relation)
      late_phase = ProjectPhase.where('project_phases.project_id = projects.id')
                               .where.not(status: DONE_PHASE_STATUSES)
                               .where("#{PHASE_DUE_SQL} < ?", today)
      relation.where(status: 'active')
              .where('projects.estimated_completion_date < :d OR EXISTS (:late)', d: today, late: late_phase)
    end

    def overdue_counts(project_ids)
      tasks = ProjectTask.active.where(project_id: project_ids, status: OPEN_TASK_STATUSES)
                         .where('due_date < ?', today).group(:project_id).count
      steps = ProjectPhaseTask.joins(:project_phase).where(project_phases: { project_id: project_ids })
                              .where(status: 'pending').where.not(project_phases: { status: DONE_PHASE_STATUSES })
                              .where('COALESCE(project_phase_tasks.estimated_completion_date, project_phases.estimated_completion_date) < ?', today)
                              .group('project_phases.project_id').count
      tasks.merge(steps) { |_k, a, b| a + b }
    end

    # Earliest date still ahead: an open task, step or phase.
    def next_due(project)
      dates = []
      dates << project.tasks.active.where(status: OPEN_TASK_STATUSES).where('due_date >= ?', today).minimum(:due_date)
      dates << project.project_phases.where.not(status: DONE_PHASE_STATUSES)
                      .where('estimated_completion_date >= ?', today).minimum(:estimated_completion_date)
      dates.compact.min
    end

    def project_summary(ctx, project, overdue: nil)
      phase = project.current_phase_id && project.project_phases.find { |p| p.id == project.current_phase_id }
      {
        id: "project:#{project.id}", title: [project.project_number, project.name].compact_blank.join(' '),
        url: url(ctx, project), name: project.name, project_number: project.project_number, status: project.status,
        progress_percent: project.progress_percent, phases_done: project.completed_phase_count,
        phase_count: project.phase_count, current_phase: phase&.name || project.current_phase_name,
        customer: project.customer_display_name, home: project.home_display_name.presence,
        owner: ctx.user_names[project.owner_id], location: ctx.location_names[project.location_id],
        started_at: project.started_at&.iso8601, estimated_completion_date: project.estimated_completion_date&.iso8601,
        actual_completion_date: project.actual_completion_date&.iso8601, next_due: next_due(project)&.iso8601,
        overdue_items: overdue, deal: project.deal_id && "deal:#{project.deal_id}"
      }.compact
    end

    def cost_fields(project)
      {
        budget: project.budget_amount&.to_f, actual_cost: project.actual_cost&.to_f,
        labor: project.labor_cost&.to_f, materials: project.materials_cost&.to_f,
        subcontractor: project.subcontractor_cost&.to_f, other: project.other_cost&.to_f,
        over_budget: project.budget_amount ? project.over_budget? : nil,
        variance: project.budget_variance&.to_f
      }.compact
    end

    def phase_detail(ctx, phase, costs:)
      due = phase.computed_completion_date
      steps = phase.project_phase_tasks.to_a
      {
        id: "phase:#{phase.id}", name: phase.name, position: phase.position, status: phase.status,
        required: phase.is_required, visible_to_client: phase.visible_to_client,
        emails_customer_on_start: phase.notify_client_on_start, emails_customer_on_complete: phase.notify_client_on_complete,
        estimated_start: phase.computed_start_date&.iso8601, estimated_completion: due&.iso8601,
        estimated_days: phase.computed_estimated_days, started_at: phase.started_at&.iso8601,
        completed_at: phase.completed_at&.iso8601, overdue: phase.overdue?,
        steps_done: steps.count { |s| s.status == 'completed' }, step_count: steps.size,
        steps: steps.map { |s| step_summary(ctx, s, phase) },
        estimated_budget: (phase.estimated_budget&.to_f if costs), actual_cost: (phase.actual_cost&.to_f if costs)
      }.compact
    end

    def step_due(step, phase)
      step.estimated_completion_date || phase.estimated_completion_date
    end

    def step_summary(ctx, step, phase, project: nil)
      due = step_due(step, phase)
      {
        id: "phase_step:#{step.id}", kind: 'phase_step', title: step.name, status: step.status,
        project: project && "project:#{project.id}", project_name: project&.name, phase: phase.name,
        assigned_to: ctx.user_names[step.assigned_to_id], due: due&.iso8601,
        due_source: (step.estimated_completion_date ? nil : ('phase' if due)),
        overdue: step.status == 'pending' && due.present? && due < today && !DONE_PHASE_STATUSES.include?(phase.status),
        required: step.is_required, visible_to_client: step.visible_to_client,
        customer_must_act: step.client_actionable || nil,
        customer_acknowledged_at: step.client_acknowledged_at&.iso8601, completed_at: step.completed_at&.iso8601
      }.compact
    end

    def task_summary(ctx, task, project: nil, phase_name: nil, costs: false)
      {
        id: "project_task:#{task.id}", kind: 'project_task', title: task.title, status: task.status,
        priority: task.priority, project: project && "project:#{project.id}", project_name: project&.name,
        phase: phase_name, assigned_to: ctx.user_names[task.assigned_to_id], due: task.due_date&.iso8601,
        overdue: OPEN_TASK_STATUSES.include?(task.status) && task.due_date.present? && task.due_date < today,
        started_at: task.started_at&.iso8601, completed_at: task.completed_at&.iso8601,
        estimated_hours: task.estimated_hours&.to_f, actual_hours: task.actual_hours&.to_f,
        estimated_cost: (task.estimated_cost&.to_f if costs), actual_cost: (task.actual_cost&.to_f if costs),
        description: task.description.to_s.first(500).presence
      }.compact
    end

    # Who hears about a change, worked out before making it, so the AI can
    # tell the person and the tool can stop when a customer would be emailed.
    #
    # event: 'task_completed' or 'phase_started'.
    def notification_recipients(project, event, phase: nil)
      prefs = project.notification_preferences.active.for_event(event).to_a
      customer = prefs.any? { |p| p.recipient_type == 'Contact' && (p.via_email || p.via_sms) }
      team = prefs.any? { |p| p.recipient_type == 'User' && (p.via_email || p.via_sms) }
      emailed = prefs.any? { |p| p.via_email && p.effective_email.present? }
      # Without a preference row that emails, ProjectNotificationService
      # emails the customer only when the phase's own switch says to (see
      # client_should_hear?), once.
      if event == 'phase_started' && !emailed && phase &&
         ProjectNotificationService.client_should_hear?(project, phase, event) &&
         ProjectNotificationService.send(:resolve_client_email, project).present?
        customer = true
      end
      { customer: customer, team: team }
    end
  end
end
