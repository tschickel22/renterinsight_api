class ReportAiService
  class AiError < StandardError; end
  class RateLimitError < StandardError; end

  MODEL = AiModel.for(:analysis)
  MAX_TOKENS = 1000

  def initialize(api_key)
    @api_key = api_key
  end

  # Translates a natural language question into ReportEngine params.
  # Returns: { query_params:, explanation:, input_tokens:, output_tokens:, cost_cents: }
  def translate(question, field_definitions_by_module, context = {})
    prompt = build_prompt(question, field_definitions_by_module, context)

    started_at = Time.current
    response = call_claude(prompt)
    elapsed_ms = ((Time.current - started_at) * 1000).to_i

    parsed = parse_response(response)

    {
      query_params: parsed[:query_params],
      explanation: parsed[:explanation],
      fully_answered: parsed[:fully_answered],
      not_covered: parsed[:not_covered],
      chart: parsed[:chart],
      input_tokens: response.dig('usage', 'input_tokens').to_i,
      output_tokens: response.dig('usage', 'output_tokens').to_i,
      cost_cents: calculate_cost_cents(
        response.dig('usage', 'input_tokens').to_i,
        response.dig('usage', 'output_tokens').to_i
      ),
      response_time_ms: elapsed_ms
    }
  end

  # Generates a one-sentence plain-English answer for a question + result rows.
  # Returns a String, or nil on failure.
  #
  # The model sees five rows. It used to be told the page size (at most 50)
  # as the number of results and asked to state a sum or average, so it
  # stated figures worked out from five rows of a capped page. It now gets
  # the true count, and when it cannot see every row it may give the count
  # but never a total or average.
  def summarize_results(question, report_data)
    rows       = report_data[:rows] || []
    columns    = report_data[:columns] || (rows.first&.keys || [])
    field_list = columns.map { |c| c.is_a?(Hash) ? (c[:label] || c['label'] || c[:key] || c['key']) : c }.join(', ')
    sample     = rows.first(5).to_json
    total      = (report_data.dig(:meta, :total) || rows.length).to_i
    complete   = rows.length >= total && rows.length <= 5
    grouped    = report_data.dig(:meta, :grouped)

    scope_line =
      if grouped
        shown = rows.first(20)
        "The report is already grouped and totalled by the database, sorted as shown, with #{total} groups" \
          "#{total > shown.size ? ", of which these are the first #{shown.size}" : ''}: #{shown.to_json}. " \
          'The figures are exact; you may state them.'
      elsif complete
        "The query matched #{total} records, all shown here: #{sample}."
      else
        "The query matched #{total} records. You can see only the first #{[rows.length, 5].min} of them: #{sample}. " \
          'If the question asks how many, answer with the number of records matched. If it asks for a total, sum, ' \
          'average, highest or lowest, do NOT work one out: say how many records matched and that the full list ' \
          'below has the details.'
      end

    prompt = <<~PROMPT
      The user asked: #{question}
      Fields: #{field_list}.
      #{scope_line}
      Write a single concise sentence directly answering the question. Do not say "based on the data" or similar filler. Never use em dashes or en dashes.
    PROMPT

    response = call_claude(prompt, max_tokens: 150)
    response.dig('content', 0, 'text')&.strip
  rescue => e
    Rails.logger.warn "[ReportAiService#summarize_results] #{e.message}"
    nil
  end

  private

  def build_prompt(question, field_definitions_by_module, context)
    today = context[:today] || Date.current.to_s
    company_name = context[:company_name] || 'the company'

    modules_summary = field_definitions_by_module.map do |mod_key, fields|
      field_list = fields.map do |f|
        type_hint = f[:type] == 'date' ? ' (date)' : f[:type] == 'number' ? ' (number)' : f[:type] == 'enum' ? ' (enum)' : ''
        "#{f[:key]}#{type_hint}"
      end.join(', ')
      "  #{mod_key}: #{field_list}"
    end.join("\n")

    stages = Array(context[:deal_stages])
    stage_lines =
      if stages.any?
        won = stages.select { |st| st[:kind] == 'won' }.map { |st| st[:key] }
        lost = stages.select { |st| st[:kind] == 'lost' }.map { |st| st[:key] }
        open = stages.select { |st| st[:kind] == 'open' }.map { |st| st[:key] }
        "THIS COMPANY'S DEAL STAGES (use these exact keys for the deals stage field, never closed_won or closed_lost unless listed):\n" \
          "#{stages.map { |st| "  #{st[:key]} (#{st[:label]}, #{st[:kind]})" }.join("\n")}\n" \
          "  won: #{won.to_json}  lost: #{lost.to_json}  open (pending, in the pipeline): #{open.to_json}"
      else
        'Deal stages: won is "closed_won", lost is "closed_lost"; the rest are open.'
      end

    <<~PROMPT
      You are a report query builder for #{company_name}, a manufactured housing and RV dealership management system.
      Today's date is #{today}.

      Available report modules and their fields:
      #{modules_summary}

      Field type notes:
      - date fields: use ISO format YYYY-MM-DD for filter values
      - enum fields: use exact lowercase values (e.g., stage: "closed_won", status: "open")
      - number fields: support gt/lt/eq operators

      Supported filter operators: eq, contains, gt, lt, in

      #{stage_lines}
      Wherever the shorthand or examples below say closed_won, closed_lost or list open stages, use this company's won, lost and open keys instead. For a deal stage of won, use "in" with the won keys.

      GROUPING AND TOTALS. When the question asks for counts, totals, averages, highest or lowest
      BY something (by salesperson, by month, by status, by source), build a grouped report:
        "group_by": one field of the module that sorts records into a few kinds (a person, status, stage, source, reason or date), never an id, record number, name, email, phone or amount,
        "group_period": "day" | "week" | "month" | "quarter" | "year" (only when group_by is a date field),
        "aggregates": up to 3 of { "fn": "count" | "sum" | "avg" | "min" | "max", "field": a number field } ({"fn":"count"} needs no field).
      Sort a grouped report with sort_by set to an aggregate key ("sum_selling_price", "avg_selling_price", "count") or the group field.
      A question for one overall number ("how many leads this month", "total sales this year") is a list report; the count comes with it.
      A chart helps a grouped report: add "chart": { "type": "bar" | "line" | "pie" } (line for a date grouped by period, pie only for 6 groups or fewer).

      SAY WHAT YOU COULD NOT DO. Always include "fully_answered": true or false. Set it false when the report
      leaves out part of what was asked: a field or comparison the modules do not have, two modules at once
      (a report reads one module), a calculation across fields (margin percent, days between two dates),
      or a figure the fields do not hold. Then set "not_covered" to one short sentence saying what is left out,
      and still build the closest report you can.

      The user asks: "#{question}"

      TREAT REPORT-BUILDING PHRASING AS REPORT QUERIES.
      A user who says any of the following is asking you to build a report, not asking
      an ambiguous question. Never bail with module_key=null just because the phrasing
      is imperative rather than interrogative:
        - "build me a ___ report"          - "make me a ___ report"
        - "create a ___ report"            - "give me a ___ report"
        - "I want a report of ___"         - "pull a list of ___"
        - "show me ___"                    - "list all ___"

      COMMON BUSINESS SHORTHAND (map to fields BEFORE bailing on null):
        - "sales" or "sales report" or "pipeline"  -> module_key: "deals"
        - "pending"                                -> filter stage NOT IN closed_won/closed_lost
                                                      (use where: [{field:"stage", operator:"in", value:["prospecting","qualification","needs_analysis","proposal","negotiation","closing"]}])
        - "open"                                   -> same as pending
        - "closed"                                 -> filter stage IN closed_won/closed_lost
        - "won" or "closed won"                    -> filter stage eq closed_won
        - "lost" or "closed lost"                  -> filter stage eq closed_lost
        - "sold homes" / "sold inventory"          -> module_key: "vehicles", filter status eq sold
        - "available homes"                        -> module_key: "vehicles", filter status eq available
        - "unpaid invoices" / "overdue"            -> module_key: "invoices", filter status NOT eq paid
        - "customers" / "buyers"                   -> module_key: "contacts"
        - "top rep" / "salesperson performance"    -> module_key: "deals", sort_by primary_salesperson

      EXAMPLES (respond with ONLY a JSON object: no markdown, no prose outside JSON):

      Question: "Show me deals closed in the past 7 days"
      {
        "module_key": "deals",
        "fields": ["id", "name", "stage", "selling_price", "primary_salesperson_id", "actual_close_date"],
        "filters": {
          "date_range": { "field": "actual_close_date", "from": "2026-04-06", "to": "2026-04-13" },
          "where": [{ "field": "stage", "operator": "eq", "value": "closed_won" }]
        },
        "sort_by": "actual_close_date",
        "sort_order": "desc",
        "explanation": "Deals won in the past 7 days, most recent first."
      }

      Question: "Build me a sales pending report"
      {
        "module_key": "deals",
        "fields": ["id", "name", "stage", "primary_salesperson_id", "selling_price", "expected_close_date"],
        "filters": {
          "where": [{ "field": "stage", "operator": "in",
                      "value": ["prospecting","qualification","needs_analysis","proposal","negotiation","closing"] }]
        },
        "sort_by": "expected_close_date",
        "sort_order": "asc",
        "explanation": "Open (pending) deals still in the sales pipeline, soonest expected close first."
      }

      Question: "Average selling price by salesperson this year"
      {
        "module_key": "deals",
        "fields": ["owner_id", "selling_price"],
        "filters": {
          "date_range": { "field": "actual_close_date", "from": "2026-01-01", "to": "2026-12-31" },
          "where": [{ "field": "stage", "operator": "eq", "value": "closed_won" }]
        },
        "group_by": "owner_id",
        "aggregates": [{ "fn": "count" }, { "fn": "avg", "field": "selling_price" }, { "fn": "sum", "field": "selling_price" }],
        "sort_by": "avg_selling_price",
        "sort_order": "desc",
        "chart": { "type": "bar" },
        "fully_answered": true,
        "explanation": "Deals won this year by salesperson: how many, the average and the total selling price."
      }

      Question: "Leads by month this year"
      {
        "module_key": "leads",
        "fields": ["created_at"],
        "filters": { "date_range": { "field": "created_at", "from": "2026-01-01", "to": "2026-12-31" } },
        "group_by": "created_at",
        "group_period": "month",
        "aggregates": [{ "fn": "count" }],
        "chart": { "type": "line" },
        "fully_answered": true,
        "explanation": "New leads each month this year."
      }

      Question: "Gross margin percent by salesperson"
      {
        "module_key": "deals",
        "fields": ["owner_id", "selling_price"],
        "filters": { "where": [{ "field": "stage", "operator": "eq", "value": "closed_won" }] },
        "group_by": "owner_id",
        "aggregates": [{ "fn": "count" }, { "fn": "sum", "field": "selling_price" }],
        "sort_by": "sum_selling_price",
        "sort_order": "desc",
        "fully_answered": false,
        "not_covered": "Reports cannot work out margin percent; this shows deals and sales by salesperson instead.",
        "explanation": "Deals won and total sales by salesperson."
      }

      Question: "Make me a report of unpaid invoices"
      {
        "module_key": "invoices",
        "fields": ["id", "invoice_number", "contact_id", "amount_due", "due_date", "status"],
        "filters": {
          "where": [{ "field": "status", "operator": "in", "value": ["sent", "overdue", "partial"] }]
        },
        "sort_by": "due_date",
        "sort_order": "asc",
        "explanation": "Invoices that are sent, overdue, or partially paid, oldest due date first."
      }

      Rules:
      - Never use em dashes or en dashes in explanation or not_covered. Use a period, comma or colon.
      - In explanation and not_covered, name fields as a person would ("salesperson", "selling price"), never by their keys (owner_id).
      - Only use fields that exist in the modules_summary above (skip any that aren't listed).
      - If a date range is implied (e.g., "this week", "past 7 days", "this month"), calculate exact dates from today.
      - If the phrasing is ambiguous, pick the most reasonable interpretation and build the query. Do NOT bail with null.
      - Only set module_key to null when the question truly can't map to any available module. In that case, set explanation to what you would need to answer it (e.g., "I need a module to query. Try asking about leads, deals, invoices, or inventory.").
    PROMPT
  end

  def call_claude(prompt, max_tokens: MAX_TOKENS)
    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = @api_key
    request['anthropic-version'] = '2023-06-01'

    body = {
      model: MODEL,
      max_tokens: max_tokens,
      messages: [{ role: 'user', content: prompt }]
    }

    response = http.request(request, body.to_json)

    unless response.code == '200'
      raise AiError, "Claude API error: #{response.code}: #{response.body&.slice(0, 200)}"
    end

    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise AiError, "Claude API timeout: #{e.message}"
  rescue JSON::ParserError => e
    raise AiError, "Invalid response from Claude: #{e.message}"
  end

  def parse_response(response)
    content = response.dig('content', 0, 'text')
    raise AiError, 'Empty response from Claude' if content.blank?

    json_str = content.gsub(/```json|```/, '').strip

    parsed = JSON.parse(json_str)

    module_key = parsed['module_key']
    explanation = parsed['explanation'] || 'Report generated from your question.'

    query_params = if module_key.present?
      {
        module: module_key,
        fields: (parsed['fields'] || []),
        filters: (parsed['filters'] || {}).deep_stringify_keys,
        sort_by: parsed['sort_by'] || 'created_at',
        sort_order: parsed['sort_order'] || 'desc',
        page: 1,
        per_page: 50
      }.merge(grouping(parsed))
    else
      nil
    end

    { query_params: query_params, explanation: explanation,
      fully_answered: parsed['fully_answered'] != false,
      not_covered: parsed['not_covered'].to_s.strip.first(300).presence,
      chart: chart(parsed) }
  rescue JSON::ParserError => e
    raise AiError, "Could not parse Claude response as JSON: #{e.message}"
  end

  # Grouping as the engine takes it (ReportEngine::Grouped checks every field).
  def grouping(parsed)
    return {} if parsed['group_by'].blank?

    { group_by: parsed['group_by'].to_s, group_period: parsed['group_period'].presence,
      aggregates: Array(parsed['aggregates']).first(3).map { |a| a.to_h.slice('fn', 'field') }.presence }.compact
  end

  CHART_TYPES = %w[bar line pie].freeze

  def chart(parsed)
    type = parsed.dig('chart', 'type').to_s
    CHART_TYPES.include?(type) && parsed['group_by'].present? ? { type: type } : nil
  end

  # Claude Sonnet 4 pricing:
  # Input:  $3.00 per million tokens
  # Output: $15.00 per million tokens
  def calculate_cost_cents(input_tokens, output_tokens)
    input_cost  = input_tokens  * 0.000003
    output_cost = output_tokens * 0.000015
    ((input_cost + output_cost) * 100).ceil
  end
end
