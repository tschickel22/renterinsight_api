# frozen_string_literal: true

module McpTools
  class ListBills < ListTool
    tool_name 'list_bills'
    title 'List vendor bills'
    description 'Vendor bills (accounts payable), soonest due first. Defaults to unpaid bills (pending or partly ' \
                'paid). overdue_only lists past due ones; due_within_days lists ones due in the next N days (overdue ' \
                'included). Filter by status or a vendor/bill number search. Totals cover every matching bill. Unless the ' \
                'dealer lets AI apps see dealer cost, bills for homes and jobs show amounts_hidden instead of their ' \
                'amounts and are left out of balance_due.'
    input_schema(
      properties: {
        status: { type: 'string', enum: %w[unpaid draft pending partially_paid paid void any] },
        overdue_only: { type: 'boolean' },
        due_within_days: { type: 'integer', minimum: 0 },
        query: { type: 'string', description: 'Vendor, bill number, memo or reference contains' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: 'unpaid', overdue_only: false, due_within_days: nil, query: nil, limit: 20)
      AccountingAccess.require!(ctx, 'bills', 'read')
      rel = AccountingAccess.bills(ctx).includes(:vendor)
      case status.to_s
      when '', 'unpaid' then rel = rel.where(status: AccountingAccess::OPEN_BILL_STATUSES)
      when 'any' then nil
      else rel = rel.where(status: status)
      end
      rel = rel.where('bills.due_date < ?', Date.current) if overdue_only
      rel = rel.where('bills.due_date <= ?', Date.current + due_within_days.to_i) if due_within_days.present?
      if query.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
        rel = rel.where('bills.vendor_name ILIKE :t OR bills.bill_number ILIKE :t OR bills.memo ILIKE :t OR ' \
                        'bills.reference_number ILIKE :t', t: term)
      end
      shown, hidden = AccountingAccess.split_cost_bills(ctx, rel)
      hidden_count = hidden.count
      totals = { bills: rel.count, balance_due: AccountingAccess.money(shown.sum(:balance_due)),
                 overdue: rel.where('bills.due_date < ?', Date.current).count }
      if hidden_count.positive?
        totals[:amounts_hidden] = hidden_count
        totals[:note] = "balance_due leaves out the #{hidden_count} bill#{'s' unless hidden_count == 1} with amounts " \
                        "hidden. #{AccountingAccess::COST_HIDDEN_NOTE}"
      end
      rows = rel.order(Arel.sql('bills.due_date ASC NULLS LAST'), :id).limit(ctx.row_limit(limit)).to_a
      hidden_ids = hidden_count.positive? ? hidden.where(id: rows.map(&:id)).pluck(:id).to_set : Set.new
      items = rows.map { |b| AccountingAccess.bill(ctx, b, hide_amounts: hidden_ids.include?(b.id)) }
      Base::Result.new(payload: { count: items.size, items: items, totals: totals }, count: items.size)
    end
  end
end
