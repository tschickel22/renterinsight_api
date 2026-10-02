# frozen_string_literal: true

module McpTools
  class ListInvoices < ListTool
    tool_name 'list_invoices'
    title 'List customer invoices'
    description 'Customer invoices (accounts receivable), oldest due first. Defaults to open invoices (sent, viewed, ' \
                'partly paid or overdue; drafts are not owed yet). overdue_only lists past due ones. Filter by status ' \
                'or an invoice number/customer search. Totals and aging buckets cover every matching invoice.'
    input_schema(
      properties: {
        status: { type: 'string', enum: %w[open draft finalized sent viewed partial overdue paid cancelled any] },
        overdue_only: { type: 'boolean' },
        query: { type: 'string', description: 'Invoice number or customer name contains' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: 'open', overdue_only: false, query: nil, limit: 20)
      AccountingAccess.require!(ctx, 'finance', 'read')
      rel = AccountingAccess.invoices(ctx).includes(:contact)
      case status.to_s
      when '', 'open' then rel = rel.where(status: AccountingAccess::OPEN_INVOICE_STATUSES).where('invoices.amount_due > 0')
      when 'any' then nil
      else rel = rel.where(status: status)
      end
      rel = rel.where('invoices.due_date < ?', Date.current).where.not(status: %w[paid cancelled draft]) if overdue_only
      if query.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
        rel = rel.left_joins(:contact).where(
          "invoices.invoice_number ILIKE :t OR contacts.first_name ILIKE :t OR contacts.last_name ILIKE :t OR " \
          "(contacts.first_name || ' ' || contacts.last_name) ILIKE :t", t: term
        )
      end
      payload = { totals: aging(rel) }
      rows = rel.order(Arel.sql('invoices.due_date ASC NULLS LAST'), :id).limit(ctx.row_limit(limit)).to_a
      items = rows.map { |i| AccountingAccess.invoice(ctx, i) }
      Base::Result.new(payload: { count: items.size, items: items }.merge(payload), count: items.size)
    end

    # Same buckets as the AR aging report.
    def self.aging(rel)
      buckets = { current: 0.to_d, days_1_30: 0.to_d, days_31_60: 0.to_d, days_61_90: 0.to_d, days_90_plus: 0.to_d }
      rel.where(status: AccountingAccess::OPEN_INVOICE_STATUSES).where('invoices.amount_due > 0')
         .pluck(:due_date, :invoice_date, :amount_due).each do |due, issued, owed|
        days = (Date.current - (due || issued || Date.current)).to_i
        bucket = if days <= 0 then :current
                 elsif days <= 30 then :days_1_30
                 elsif days <= 60 then :days_31_60
                 elsif days <= 90 then :days_61_90
                 else :days_90_plus
                 end
        buckets[bucket] += owed.to_d
      end
      { invoices: rel.count, open_balance: AccountingAccess.money(buckets.values.sum),
        aging: buckets.transform_values { |v| AccountingAccess.money(v) } }
    end
  end
end
