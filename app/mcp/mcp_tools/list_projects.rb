# frozen_string_literal: true

module McpTools
  class ListProjects < ListTool
    tool_name 'list_projects'
    title 'List projects'
    description 'List home setup and installation projects, most recently updated first, with progress, current ' \
                'phase, next due date and how many steps or tasks are overdue. status: active (default), ' \
                'completed, on_hold, cancelled or any. owner: "me" or a user id. behind_schedule=true lists active ' \
                'projects past their estimated completion date or with a phase past its estimated completion.'
    input_schema(
      properties: {
        status: { type: 'string', enum: %w[active completed on_hold cancelled any] },
        owner: { type: 'string', description: '"me" or a user id' },
        behind_schedule: { type: 'boolean' },
        query: { type: 'string', description: 'Project name or number, customer, or home make/model' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: 'active', owner: nil, behind_schedule: false, query: nil, limit: 20)
      rel = ProjectSupport.projects(ctx)
      rel = rel.where(status: status.presence || 'active') unless status == 'any'
      rel = rel.where(owner_id: owner == 'me' ? ctx.user.id : owner.to_i) if owner.present?
      rel = ProjectSupport.behind_schedule_ids(rel) if behind_schedule
      if query.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
        rel = rel.where('projects.name ILIKE :t OR projects.project_number ILIKE :t OR projects.customer_name ILIKE :t OR ' \
                        'projects.home_make ILIKE :t OR projects.home_model ILIKE :t', t: term)
      end

      rows = rel.includes(:project_phases, :deal).order(updated_at: :desc).limit(ctx.row_limit(limit)).to_a
      overdue = ProjectSupport.overdue_counts(rows.map(&:id))
      items = rows.map { |p| ProjectSupport.project_summary(ctx, p, overdue: overdue.fetch(p.id, 0)) }
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
    end
  end
end
