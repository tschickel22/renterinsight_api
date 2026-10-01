# frozen_string_literal: true

module McpTools
  # Counts and totals only, so it does not draw on the daily record budget.
  class PipelineSummary < Base
    tool_name 'pipeline_summary'
    title 'Pipeline summary'
    description 'A snapshot of the sales pipeline the user can see: open deals per stage with their total ' \
                'selling price, deals won and lost this month, and open leads per status with how many came ' \
                'in over the last 7 and 30 days.'
    input_schema(properties: {})
    read_only!

    def self.perform(ctx)
      records = Records.new(ctx)
      company = ctx.company
      payload = {}

      if ctx.can?('deals', 'read')
        deals = records.scope('deal')
        closed = company.closed_deal_stage_keys
        open = deals.where.not('LOWER(COALESCE(deals.stage, \'\')) IN (?)', closed)
        grouped = open.group(Arel.sql('LOWER(deals.stage)')).pluck(Arel.sql('LOWER(deals.stage)'), Arel.sql('COUNT(*)'),
                                                                     Arel.sql('COALESCE(SUM(deals.selling_price), 0)'))
        labels = company.pipeline_stages.to_h { |s| [(s['key'] || s[:key]).to_s.downcase, s['name'] || s[:name]] }
        month = (Time.current.beginning_of_month..)
        payload[:open_deals_by_stage] = grouped.map do |stage, count, total|
          { stage: stage, label: labels[stage], count: count, total_selling_price: total.to_f }
        end
        payload[:won_this_month] = deals.where('LOWER(deals.stage) IN (?)', company.won_stage_keys).where(updated_at: month).count
        payload[:lost_this_month] = deals.where('LOWER(deals.stage) IN (?)', company.lost_stage_keys).where(updated_at: month).count
      end

      if ctx.can?('leads', 'read')
        leads = records.scope('lead')
        payload[:open_leads_by_status] = leads.group(:status).count.map { |status, count| { status: status, count: count } }
        payload[:new_leads_last_7_days] = leads.where(created_at: 7.days.ago..).count
        payload[:new_leads_last_30_days] = leads.where(created_at: 30.days.ago..).count
      end

      raise Denied, 'Your role cannot read deals or leads.' if payload.empty?

      payload
    end
  end
end
