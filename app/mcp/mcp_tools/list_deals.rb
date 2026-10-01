# frozen_string_literal: true

module McpTools
  class ListDeals < ListTool
    tool_name 'list_deals'
    title 'List deals'
    description 'List deals, most recently updated first. Filter by pipeline stage key (see get_reference_data), ' \
                'open vs closed, the salesperson ("me" or a user id), or a name/deal number/customer search. ' \
                'stale_days lists open deals not updated in that many days.'
    input_schema(
      properties: {
        stage: { type: 'string' },
        state: { type: 'string', enum: %w[open won lost any] },
        salesperson: { type: 'string', description: '"me" or a user id' },
        stale_days: { type: 'integer', minimum: 1 },
        query: { type: 'string' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, stage: nil, state: 'open', salesperson: nil, stale_days: nil, query: nil, limit: 20)
      records = Records.new(ctx)
      company = ctx.company
      rel = records.scope('deal')
      rel = rel.where(id: records.search('deal', query, 500).map(&:id)) if query.present?
      rel = rel.where('LOWER(deals.stage) = ?', stage.to_s.downcase) if stage.present?
      case state
      when 'won' then rel = rel.where('LOWER(deals.stage) IN (?)', company.won_stage_keys)
      when 'lost' then rel = rel.where('LOWER(deals.stage) IN (?)', company.lost_stage_keys)
      when 'any' then nil
      else rel = rel.where.not('LOWER(COALESCE(deals.stage, \'\')) IN (?)', company.closed_deal_stage_keys)
      end
      if salesperson.present?
        uid = salesperson == 'me' ? ctx.user.id : salesperson.to_i
        rel = rel.where('deals.primary_salesperson_id = :u OR deals.owner_id = :u OR deals.user_id = :u', u: uid)
      end
      rel = rel.where('deals.updated_at < ?', stale_days.to_i.days.ago) if stale_days.present?
      listing(ctx, 'deal', rel.order(updated_at: :desc), limit)
    end
  end
end
