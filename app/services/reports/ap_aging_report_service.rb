# frozen_string_literal: true

module Reports
  class ApAgingReportService
    def initialize(company)
      @company = company
    end

    def generate(as_of_date: Date.current, location_id: nil)
      pos = @company.purchase_orders
        .where(status: ['submitted', 'approved', 'partially_received', 'received'])

      pos = pos.where(is_deleted: false) if pos.column_names.include?('is_deleted')

      buckets = { current: [], days_1_30: [], days_31_60: [], days_61_90: [], days_90_plus: [] }
      totals = { current: BigDecimal('0'), days_1_30: BigDecimal('0'), days_31_60: BigDecimal('0'), days_61_90: BigDecimal('0'), days_90_plus: BigDecimal('0') }

      pos.each do |po|
        due_date = po.try(:due_date) || po.try(:expected_date) || po.try(:expected_delivery_date) || po.created_at.to_date
        days_past = (as_of_date - due_date).to_i
        balance = (po.try(:total_amount) || BigDecimal('0')) - (po.try(:paid_amount) || BigDecimal('0'))
        next if balance <= 0

        row = {
          po_id: po.id,
          po_number: po.try(:po_number),
          supplier_name: po.try(:supplier)&.name || 'Unknown',
          supplier_id: po.try(:supplier_id),
          po_date: po.created_at.to_date,
          due_date: due_date,
          total: po.try(:total_amount),
          balance_due: balance,
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
        totals[bucket] += balance
      rescue => e
        Rails.logger.warn("[ApAging] Error processing PO #{po.id}: #{e.message}")
        next
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
          total_items: buckets.values.flatten.count,
          current_pct: grand_total.zero? ? 0 : (totals[:current] / grand_total * 100).round(1),
          past_due_pct: grand_total.zero? ? 0 : ((grand_total - totals[:current]) / grand_total * 100).round(1)
        }
      }
    end
  end
end
