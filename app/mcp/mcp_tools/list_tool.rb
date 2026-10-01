# frozen_string_literal: true

module McpTools
  # Shared shape for the list_* tools: filter, cap, summarize.
  class ListTool < Base
    # MCP::Tool.inherited clears annotations on every subclass, so marking
    # this class read only would not reach list_leads and the rest.
    def self.inherited(subclass)
      super
      subclass.read_only!
    end

    def self.listing(ctx, type, relation, limit, extra = {})
      records = Records.new(ctx)
      rows = relation.limit(ctx.row_limit(limit)).to_a
      items = rows.map { |r| records.summary(type, r) }
      Base::Result.new(payload: { count: items.size, items: items }.merge(extra), count: items.size)
    end

    def self.parse_date(value, field)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise UserError, "#{field} must be a date like 2026-09-30."
    end
  end
end
