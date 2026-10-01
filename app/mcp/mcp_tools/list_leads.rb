# frozen_string_literal: true

module McpTools
  class ListLeads < ListTool
    tool_name 'list_leads'
    title 'List leads'
    description 'List open leads (not yet converted), newest first unless sort says otherwise. Filter by status ' \
                'key, by owner ("me", "unassigned" or a user id from get_reference_data), by when they came in, ' \
                'or by a name/email/phone search. sort=stale lists the leads nobody has touched longest.'
    input_schema(
      properties: {
        status: { type: 'string', description: 'A lead status key from get_reference_data' },
        owner: { type: 'string', description: '"me", "unassigned", or a user id' },
        created_after: { type: 'string', description: 'ISO date, e.g. 2026-09-01' },
        query: { type: 'string', description: 'Name, email or phone contains' },
        sort: { type: 'string', enum: %w[newest stale recent_activity] },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: nil, owner: nil, created_after: nil, query: nil, sort: 'newest', limit: 20)
      records = Records.new(ctx)
      rel = records.scope('lead')
      rel = rel.where(id: records.search('lead', query, 500).map(&:id)) if query.present?
      rel = rel.where(status: status) if status.present?
      case owner.to_s
      when '' then nil
      when 'me' then rel = rel.where(owner_id: ctx.user.id)
      when 'unassigned' then rel = rel.where(owner_id: nil)
      else rel = rel.where(owner_id: owner.to_i)
      end
      if (date = parse_date(created_after, 'created_after'))
        rel = rel.where('leads.created_at >= ?', date.beginning_of_day)
      end
      rel = case sort
            when 'stale' then rel.order(Arel.sql('leads.last_activity_at ASC NULLS FIRST'))
            when 'recent_activity' then rel.order(Arel.sql('leads.last_activity_at DESC NULLS LAST'))
            else rel.order(created_at: :desc)
            end
      listing(ctx, 'lead', rel, limit)
    end
  end
end
