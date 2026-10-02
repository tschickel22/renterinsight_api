# frozen_string_literal: true

module McpTools
  class GetProject < Base
    tool_name 'get_project'
    title 'Get a project'
    description 'Full status of one project: customer, home, delivery address, every phase in order with its ' \
                'status, estimated and actual dates and checklist steps, and the open project tasks with ' \
                'assignees and due dates. Job costs against budget appear only when the dealer allows cost ' \
                'figures through the connector.'
    input_schema(
      properties: { id: { type: 'string', description: 'project:12' } },
      required: ['id']
    )
    read_only!

    def self.perform(ctx, id:)
      ctx.row_limit(1)
      project = ProjectSupport.find_project(ctx, id)
      costs = ProjectSupport.costs_visible?(ctx)
      phases = project.project_phases.includes(:project_phase_tasks).ordered.to_a
      phase_names = phases.to_h { |ph| [ph.id, ph.name] }
      open_tasks = project.tasks.active.where(status: ProjectSupport::OPEN_TASK_STATUSES)
                          .order(Arel.sql('due_date ASC NULLS LAST'), :position).limit(Context::MAX_ROWS).to_a

      payload = ProjectSupport.project_summary(ctx, project, overdue: ProjectSupport.overdue_counts([project.id])
                                                                                    .fetch(project.id, 0)).merge(
        description: project.description.to_s.first(1500).presence,
        customer_email: project.customer_email, customer_phone: project.customer_phone,
        home_serial_number: project.home_serial_number, unit: project.vehicle_id && "unit:#{project.vehicle_id}",
        delivery_address: project.delivery_address_display.presence,
        customer_portal_on: project.client_visible,
        costs: (ProjectSupport.cost_fields(project) if costs),
        costs_hidden: (unless costs
                         'Job costs are hidden: the dealer has not turned on "Let AI apps see dealer cost and gross" ' \
                           'under Settings, Integrations, AI Apps, or this person cannot read projects.'
                       end),
        phases: phases.map { |ph| ProjectSupport.phase_detail(ctx, ph, costs: costs) },
        open_tasks: open_tasks.map { |t| ProjectSupport.task_summary(ctx, t, phase_name: phase_names[t.project_phase_id], costs: costs) },
        open_task_count: project.tasks.active.where(status: ProjectSupport::OPEN_TASK_STATUSES).count
      ).compact
      Base::Result.new(payload: payload, count: 1)
    end
  end
end
