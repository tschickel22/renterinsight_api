# frozen_string_literal: true

module McpTools
  class ListWorkflows < ListTool
    tool_name 'list_workflows'
    title 'List workflow automations'
    description 'List workflow automations with status (draft, active, paused, archived), what starts them, ' \
                'the kinds of steps they take, and how often they have run. Read only.'
    input_schema(
      properties: {
        status: { type: 'string', enum: %w[draft active paused archived] },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: nil, limit: 20)
      MarketingAccess.require_workflows!(ctx, 'read')
      rel = ctx.company.workflow_rules
      rel = status.present? ? rel.where(status: status) : rel.where.not(status: 'archived')
      rows = rel.order(updated_at: :desc).limit(ctx.row_limit(limit)).to_a
      runs = WorkflowRun.where(workflow_rule_id: rows.map(&:id)).group(:workflow_rule_id).count
      last = WorkflowRun.where(workflow_rule_id: rows.map(&:id)).group(:workflow_rule_id).maximum(:created_at)
      items = rows.map do |r|
        {
          id: "workflow:#{r.id}", name: r.name, status: r.status, record_type: r.entity_type,
          starts_on: (r.trigger || {})['event_type'],
          step_types: Array((r.steps || {})['nodes']).map { |n| n['type'] }.compact,
          runs: runs[r.id] || 0, last_run_at: last[r.id]&.iso8601, url: MarketingAccess.workflow_url(ctx, r)
        }
      end
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
    end
  end
end
