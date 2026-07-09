# frozen_string_literal: true

module Reports
  class DealProfitabilityReportService
    def initialize(company)
      @company = company
    end

    def generate(start_date: nil, end_date: nil, location_id: nil, salesperson_id: nil)
      deals = @company.deals
      deals = deals.where(location_id: location_id) if location_id && deals.column_names.include?('location_id')

      if start_date && end_date
        # Prefer the semantic close date over updated_at — updated_at advances
        # on any edit and would knock a closed deal out of the report whenever
        # someone touches it.
        date_col =
          if deals.column_names.include?('closed_at') then 'closed_at'
          elsif deals.column_names.include?('won_at')  then 'won_at'
          else 'updated_at'
          end
        # Inclusive end_date: cover the full end-day, not midnight.
        deals = deals.where("#{date_col} >= ? AND #{date_col} < ?", start_date, end_date.to_date + 1)
      end

      if salesperson_id
        rep_col = deals.column_names.include?('sales_rep_id') ? 'sales_rep_id' : 'owner_id'
        deals = deals.where(rep_col => salesperson_id) if deals.column_names.include?(rep_col)
      end

      closed_keys = (@company.won_stage_keys | %w[closed completed]).map(&:downcase)
      status_col = deals.column_names.include?('stage') ? 'stage' : 'status'
      deals = deals.where("LOWER(#{status_col}) IN (?)", closed_keys)

      deal_rows = deals.map do |deal|
        Accounting::DealAccountingService.new(deal).profitability_summary
      end

      total_revenue = deal_rows.sum { |d| d[:selling_price] }
      total_front = deal_rows.sum { |d| d[:front_gross] || 0 }
      total_back = deal_rows.sum { |d| d[:back_gross] || 0 }
      total_gross = deal_rows.sum { |d| d[:total_gross] }
      total_commission = deal_rows.sum { |d| d[:commission] }
      total_net = deal_rows.sum { |d| d[:net_profit] }

      {
        period: { start_date: start_date, end_date: end_date },
        location_id: location_id,
        deals: deal_rows,
        summary: {
          deal_count: deal_rows.count,
          total_revenue: total_revenue,
          total_front_gross: total_front,
          total_back_gross: total_back,
          total_gross_profit: total_gross,
          avg_front_gross: deal_rows.any? ? (total_front / deal_rows.count).round(2) : 0,
          avg_back_gross: deal_rows.any? ? (total_back / deal_rows.count).round(2) : 0,
          avg_gross_profit: deal_rows.any? ? (total_gross / deal_rows.count).round(2) : 0,
          total_commission: total_commission,
          total_net_profit: total_net,
          gross_margin: total_revenue.zero? ? 0 : (total_gross / total_revenue * 100).round(2)
        }
      }
    end
  end
end
