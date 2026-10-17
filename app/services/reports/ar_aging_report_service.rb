# frozen_string_literal: true

module Reports
  class ArAgingReportService
    def initialize(company)
      @company = company
    end

    def generate(as_of_date: Date.current, location_id: nil)
      invoices = @company.invoices
        .includes(:contact)
        .where(status: ['sent', 'partial', 'overdue', 'finalized', 'viewed', 'pending'])
        .where('amount_due > 0')
        .where(is_deleted: [false, nil])

      invoices = invoices.where(location_id: location_id) if location_id && invoices.column_names.include?('location_id')

      buckets = { current: [], days_1_30: [], days_31_60: [], days_61_90: [], days_90_plus: [] }
      totals = { current: BigDecimal('0'), days_1_30: BigDecimal('0'), days_31_60: BigDecimal('0'), days_61_90: BigDecimal('0'), days_90_plus: BigDecimal('0') }

      invoices.each do |invoice|
        balance = invoice.try(:balance_due) || invoice.try(:amount_due) || BigDecimal('0')
        next if balance <= 0

        aging_slices(invoice, balance).each do |slice|
          days_past = (as_of_date - slice[:due_date]).to_i
          row = {
            id: invoice.id,
            # One invoice can age in several buckets (a deal invoice's draws).
            row_key: slice[:key],
            reference_number: [invoice.try(:invoice_number) || "##{invoice.id}", slice[:label]].compact.join(' · '),
            draw: slice[:label],
            party: {
              id: invoice.try(:contact_id) || invoice.try(:customer_id),
              name: resolve_invoice_contact(invoice)
            },
            document_date: (invoice.try(:invoice_date) || invoice.created_at.to_date).to_s,
            due_date: slice[:due_date].to_s,
            total: invoice.try(:total) || invoice.try(:subtotal),
            balance_due: slice[:balance],
            days_past_due: [days_past, 0].max
          }

          bucket = case days_past
                   when ..0 then :current
                   when 1..30 then :days_1_30
                   when 31..60 then :days_31_60
                   when 61..90 then :days_61_90
                   else :days_90_plus
                   end

          buckets[bucket] << row
          totals[bucket] += slice[:balance]
        end
      end

      grand_total = totals.values.sum

      {
        as_of_date: as_of_date,
        location_id: location_id,
        buckets: {
          current: { label: 'Current', items: buckets[:current], total: totals[:current] },
          days_1_30: { label: '1-30 Days', items: buckets[:days_1_30], total: totals[:days_1_30] },
          days_31_60: { label: '31-60 Days', items: buckets[:days_31_60], total: totals[:days_31_60] },
          days_61_90: { label: '61-90 Days', items: buckets[:days_61_90], total: totals[:days_61_90] },
          days_90_plus: { label: '90+ Days', items: buckets[:days_90_plus], total: totals[:days_90_plus] }
        },
        grand_total: grand_total,
        summary: {
          total_invoices: buckets.values.flatten.map { |r| r[:id] }.uniq.count,
          current_pct: grand_total.zero? ? 0 : (totals[:current] / grand_total * 100).round(1),
          past_due_pct: grand_total.zero? ? 0 : ((grand_total - totals[:current]) / grand_total * 100).round(1)
        }
      }
    end

    private

    # What is owed on an invoice and when. A deal invoice with draws ages by
    # each unpaid draw's own due date (E78): it used to age by the invoice's
    # due date, which is the last draw's, so a late first draw looked current.
    # Anything the draws don't account for ages by the invoice's due date.
    def aging_slices(invoice, balance)
      due = invoice.try(:due_date) || invoice.try(:invoice_date) || invoice.created_at.to_date
      unpaid = DrawProgress.call(invoice).select { |d| d[:balance] > DrawProgress::TOLERANCE }
      return [{ key: invoice.id.to_s, label: nil, due_date: due, balance: balance }] if unpaid.empty?

      slices = unpaid.map do |d|
        { key: "#{invoice.id}-#{d[:position]}", label: d[:description].presence || "Draw #{d[:position]}",
          due_date: d[:due_date] || due, balance: [d[:balance], balance].min }
      end
      rest = balance - slices.sum { |sl| sl[:balance] }
      slices << { key: "#{invoice.id}-rest", label: 'Other', due_date: due, balance: rest } if rest > DrawProgress::TOLERANCE
      slices
    end

    def resolve_invoice_contact(invoice)
      if invoice.respond_to?(:contact) && invoice.contact
        "#{invoice.contact.try(:first_name)} #{invoice.contact.try(:last_name)}".strip
      elsif invoice.respond_to?(:customer_name)
        invoice.customer_name
      else
        "Unknown"
      end
    end
  end
end
