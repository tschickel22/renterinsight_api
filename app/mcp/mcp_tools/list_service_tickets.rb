# frozen_string_literal: true

module McpTools
  class ListServiceTickets < ListTool
    # ServiceTicket validates these inline and exposes no constant.
    STATUSES = %w[pending_review open in_progress waiting_on_manufacturer waiting_parts completed cancelled].freeze

    tool_name 'list_service_tickets'
    title 'List service tickets'
    description 'List service tickets, newest first. By default only open ones (not completed or cancelled). ' \
                'Filter by status, priority, or assignee ("me" or a user id).'
    input_schema(
      properties: {
        status: { type: 'string', enum: STATUSES + %w[open_any any] },
        priority: { type: 'string', enum: %w[low medium high urgent] },
        assigned_to: { type: 'string', description: '"me" or a user id' },
        query: { type: 'string', description: 'Ticket number or title contains' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: 'open_any', priority: nil, assigned_to: nil, query: nil, limit: 20)
      records = Records.new(ctx)
      rel = records.scope('ticket')
      rel = rel.where(id: records.search('ticket', query, 500).map(&:id)) if query.present?
      case status.to_s
      when '', 'open_any' then rel = rel.where.not(status: %w[completed cancelled])
      when 'any' then nil
      else rel = rel.where(status: status)
      end
      rel = rel.where(priority: priority) if priority.present?
      if assigned_to.present?
        rel = rel.where(assigned_to: (assigned_to == 'me' ? ctx.user.id : assigned_to.to_i).to_s)
      end
      listing(ctx, 'ticket', rel.order(created_at: :desc), limit)
    end
  end
end
