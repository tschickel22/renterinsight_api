# frozen_string_literal: true

module McpTools
  class ListQuotes < ListTool
    tool_name 'list_quotes'
    title 'List quotes'
    description 'List customer quotes, newest first, optionally by status. Use expiring_within_days to find ' \
                'sent quotes about to lapse.'
    input_schema(
      properties: {
        status: { type: 'string', enum: Quote::STATUSES },
        expiring_within_days: { type: 'integer', minimum: 0 },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: nil, expiring_within_days: nil, limit: 20)
      rel = Records.new(ctx).scope('quote')
      rel = rel.where(status: status) if status.present?
      if expiring_within_days.present?
        rel = rel.where(status: %w[sent viewed])
                 .where(valid_until: Date.current..expiring_within_days.to_i.days.from_now.to_date)
      end
      listing(ctx, 'quote', rel.order(created_at: :desc), limit)
    end
  end
end
