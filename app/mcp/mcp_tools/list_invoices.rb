# frozen_string_literal: true

module McpTools
  class ListInvoices < ListTool
    tool_name 'list_invoices'
    title 'List customer invoices'
    description 'Customer invoices (accounts receivable), oldest due first, or largest balance first with ' \
                'sort largest. Defaults to open invoices (sent, viewed, ' \
                'partly paid or overdue; drafts are not owed yet). overdue_only lists past due ones. Filter by status ' \
                'or an invoice number/customer search. totals.matching_invoices counts every invoice the filter ' \
                'matched; totals.open_invoices, open_balance and the aging buckets cover the matching invoices that ' \
                'are open with a balance due (the same set accounting_summary counts), with a count per bucket and ' \
                'the oldest past due invoice. Each open item carries its aging_bucket.'
    input_schema(
      properties: {
        status: { type: 'string', enum: %w[open draft finalized sent viewed partial overdue paid cancelled any] },
        overdue_only: { type: 'boolean' },
        query: { type: 'string', description: 'Invoice number or customer name contains' },
        sort: { type: 'string', enum: %w[oldest largest], description: 'oldest due first (default) or largest amount due first' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: 'open', overdue_only: false, query: nil, sort: 'oldest', limit: 20)
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
      # matching_invoices is everything the filter matched (a status filter
      # of paid or any includes invoices that owe nothing); the aging block
      # always counts open invoices with a balance, the same set
      # accounting_summary counts.
      payload = { totals: { matching_invoices: rel.count }.merge(aging(rel, ctx.company)) }
      order = sort.to_s == 'largest' ? Arel.sql('invoices.amount_due DESC NULLS LAST, invoices.due_date ASC') : Arel.sql('invoices.due_date ASC NULLS LAST')
      rows = rel.order(order, :id).limit(ctx.row_limit(limit)).to_a
      items = rows.map { |i| AccountingAccess.invoice(ctx, i) }
      shown = { count: items.size, items: items }
      shown[:more_not_shown] = payload[:totals][:matching_invoices] - items.size if payload[:totals][:matching_invoices] > items.size
      Base::Result.new(payload: shown.merge(payload), count: items.size)
    end

    COUNTED = 'Open invoices with a balance due: status finalized, sent, viewed, partial or overdue, and amount due ' \
              'above zero. Drafts, paid and cancelled invoices are left out, as are future loan payments not yet due.'
    BUCKETS = %i[current days_1_30 days_31_60 days_61_90 days_90_plus].freeze

    # Days past the due date (the invoice date when there is none), as the
    # AR aging report ages them. Zero or less is current.
    def self.days_past_due(due, issued)
      (Date.current - (due || issued || Date.current)).to_i
    end

    def self.bucket(days)
      if days <= 0 then :current
      elsif days <= 30 then :days_1_30
      elsif days <= 60 then :days_31_60
      elsif days <= 90 then :days_61_90
      else :days_90_plus
      end
    end

    def self.open_with_balance(rel)
      rel.where(status: AccountingAccess::OPEN_INVOICE_STATUSES).where('invoices.amount_due > 0')
    end

    # Same buckets as the AR aging report, with how many invoices sit in each
    # and the oldest past due one named, so a bucket can be checked rather
    # than guessed from amounts (several loan invoices share one amount).
    def self.aging(rel, company)
      amounts = BUCKETS.index_with { 0.to_d }
      counts = BUCKETS.index_with { 0 }
      names = BUCKETS.index_with { [] }
      oldest = nil
      customers = Hash.new { |h, k| h[k] = { invoices: 0, balance: 0.to_d, oldest_days: nil } }
      open_with_balance(rel).reorder(:due_date, :id)
                            .pluck(:invoice_number, :due_date, :invoice_date, :amount_due, :contact_id).each do |number, due, issued, owed, contact_id|
        days = days_past_due(due, issued)
        key = bucket(days)
        amounts[key] += owed.to_d
        counts[key] += 1
        names[key] << number if names[key].size < 5
        row = customers[contact_id]
        row[:invoices] += 1
        row[:balance] += owed.to_d
        row[:oldest_days] = days if days.positive? && (row[:oldest_days].nil? || days > row[:oldest_days])
        oldest = { invoice_number: number, due_date: (due || issued)&.iso8601, days_past_due: days, amount_due: AccountingAccess.money(owed) } if days.positive? && (oldest.nil? || days > oldest[:days_past_due])
      end
      { counted: COUNTED, open_invoices: counts.values.sum, open_balance: AccountingAccess.money(amounts.values.sum),
        aging: amounts.transform_values { |v| AccountingAccess.money(v) }, aging_counts: counts,
        # Up to five invoice numbers per bucket: loan invoices often share one
        # amount, and an AI matched a bucket total to the wrong invoice twice.
        aging_invoices: names.reject { |_, v| v.empty? },
        oldest_past_due: oldest, by_customer: by_customer(company, customers) }.compact
    end

    # A dealer chases a customer, not an invoice: one call covers eight loan
    # invoices. The ten largest balances, with how many invoices and the
    # oldest days past due.
    def self.by_customer(company, customers)
      top = customers.sort_by { |_, r| -r[:balance] }.first(10)
      names = company.contacts.where(id: top.map(&:first).compact).pluck(:id, :first_name, :last_name)
                     .to_h { |id, first, last| [id, [first, last].compact_blank.join(' ')] }
      top.map do |contact_id, r|
        { customer: names[contact_id].presence || 'No customer on the invoice', customer_id: contact_id && "contact:#{contact_id}",
          open_invoices: r[:invoices], balance: AccountingAccess.money(r[:balance]), oldest_days_past_due: r[:oldest_days] || 0 }
      end
    end
  end
end
