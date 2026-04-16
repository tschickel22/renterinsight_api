require 'net/http'
require 'json'

class AiDigestService
  class DigestError < StandardError; end

  MODEL = 'claude-sonnet-4-20250514'
  MAX_TOKENS = 600

  def initialize(api_key)
    @api_key = api_key
  end

  # Generates digest for a single company.
  # Returns: { summary:, sections:[], input_tokens:, output_tokens:, cost_cents: }
  def generate_for_company(company)
    stats  = gather_stats(company)
    prompt = build_digest_prompt(stats, company.name)

    response     = call_claude(prompt)
    content      = response.dig('content', 0, 'text')&.strip
    in_tokens    = response.dig('usage', 'input_tokens').to_i
    out_tokens   = response.dig('usage', 'output_tokens').to_i

    {
      summary:       content,
      stats:         stats,
      input_tokens:  in_tokens,
      output_tokens: out_tokens,
      cost_cents:    (((in_tokens * 0.000003) + (out_tokens * 0.000015)) * 100).ceil
    }
  end

  private

  def gather_stats(company)
    now        = Time.current
    week_start = now.beginning_of_week
    week_end   = now.end_of_week
    prev_start = 1.week.ago.beginning_of_week
    prev_end   = 1.week.ago.end_of_week

    # Leads
    new_leads_this_week  = company.leads.where(created_at: week_start..now).count
    new_leads_last_week  = company.leads.where(created_at: prev_start..prev_end).count
    leads_no_contact     = company.leads.where(is_converted: [false, nil])
                             .where('updated_at < ?', 7.days.ago)
                             .where.not(status: %w[closed_lost lost_lead not_qualified junk_lead])
                             .count

    # Deals
    deals_closed_this_week = company.deals.where(stage: 'closed_won')
                               .where('won_at >= ? OR updated_at >= ?', week_start, week_start).count rescue 0
    deals_closing_soon     = company.deals.where(stage: %w[proposal negotiation closing])
                               .where(expected_close_date: now..2.weeks.from_now).count rescue 0
    pipeline_value         = company.deals.where(stage: %w[prospecting qualification needs_analysis
                               proposal negotiation closing]).sum(:value).to_f rescue 0

    # Service Tickets
    overdue_tickets  = company.service_tickets.where(status: %w[open in_progress pending_review])
                         .where('scheduled_date < ?', Date.current).count rescue 0
    open_tickets     = company.service_tickets.where(status: %w[open in_progress]).count rescue 0

    # Invoices
    unpaid_invoices  = company.invoices.where(status: %w[sent viewed partial overdue])
                         .where(is_deleted: [false, nil]).count rescue 0
    revenue_this_week = company.invoices.where(status: 'paid', is_deleted: [false, nil])
                          .where('paid_at >= ?', week_start).sum(:total).to_f rescue 0

    {
      week:                    "#{week_start.strftime('%b %d')} – #{now.strftime('%b %d, %Y')}",
      new_leads_this_week:     new_leads_this_week,
      new_leads_last_week:     new_leads_last_week,
      leads_no_contact_7_days: leads_no_contact,
      deals_closed_this_week:  deals_closed_this_week,
      deals_closing_2_weeks:   deals_closing_soon,
      pipeline_value:          pipeline_value.round(0),
      overdue_service_tickets: overdue_tickets,
      open_service_tickets:    open_tickets,
      unpaid_invoices:         unpaid_invoices,
      revenue_this_week:       revenue_this_week.round(0)
    }
  end

  def build_digest_prompt(stats, company_name)
    <<~PROMPT
      You are a business analyst for #{company_name}, a manufactured housing and RV dealership.
      Write a concise Monday morning briefing (5-7 sentences, no headers, no bullet points).

      This week's data (#{stats[:week]}):
      - New leads: #{stats[:new_leads_this_week]} (vs #{stats[:new_leads_last_week]} last week)
      - Leads with no contact in 7+ days: #{stats[:leads_no_contact_7_days]}
      - Deals closed this week: #{stats[:deals_closed_this_week]}
      - Deals closing in next 2 weeks: #{stats[:deals_closing_2_weeks]}
      - Total pipeline value: $#{stats[:pipeline_value].to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}
      - Overdue service tickets: #{stats[:overdue_service_tickets]}
      - Revenue collected this week: $#{stats[:revenue_this_week].to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}
      - Unpaid invoices outstanding: #{stats[:unpaid_invoices]}

      Tone: direct, actionable, like a trusted advisor. Highlight the 1-2 most important things
      to focus on. If leads haven't been contacted, make that urgent. If deals are closing soon, note it.
      End with one clear action recommendation.
    PROMPT
  end

  def call_claude(prompt)
    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    request = Net::HTTP::Post.new(uri)
    request['Content-Type']      = 'application/json'
    request['x-api-key']         = @api_key
    request['anthropic-version'] = '2023-06-01'
    response = http.request(request, {
      model: MODEL, max_tokens: MAX_TOKENS,
      messages: [{ role: 'user', content: prompt }]
    }.to_json)
    raise DigestError, "Claude API error: #{response.code}" unless response.code == '200'
    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise DigestError, "Timeout: #{e.message}"
  end
end
