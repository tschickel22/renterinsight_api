class ReportAiService
  class AiError < StandardError; end
  class RateLimitError < StandardError; end

  MODEL = 'claude-sonnet-4-6'
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
  def summarize_results(question, report_data)
    rows       = report_data[:rows] || []
    columns    = report_data[:columns] || (rows.first&.keys || [])
    field_list = columns.map(&:to_s).join(', ')
    sample     = rows.first(5).to_json

    prompt = <<~PROMPT
      The user asked: #{question}
      The query returned #{rows.length} rows with these fields: #{field_list}.
      Here is a sample of the data: #{sample}.
      Write a single concise sentence directly answering the question. If it is a count/sum/average, state the number clearly. Do not say "based on the data" or similar filler. Just answer directly.
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

      The user asks: "#{question}"

      TREAT REPORT-BUILDING PHRASING AS REPORT QUERIES.
      A user who says any of the following is asking you to build a report — not asking
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

      EXAMPLES (respond with ONLY a JSON object — no markdown, no prose outside JSON):

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

      Question: "Make me a report of unpaid invoices"
      {
        "module_key": "invoices",
        "fields": ["id", "invoice_number", "contact_id", "amount_due", "due_date", "status"],
        "filters": {
          "where": [{ "field": "status", "operator": "in", "value": ["sent", "overdue", "partial"] }]
        },
        "sort_by": "due_date",
        "sort_order": "asc",
        "explanation": "Invoices that are sent, overdue, or partially paid — oldest due date first."
      }

      Rules:
      - Only use fields that exist in the modules_summary above (skip any that aren't listed).
      - If a date range is implied (e.g., "this week", "past 7 days", "this month"), calculate exact dates from today.
      - If the phrasing is ambiguous, pick the most reasonable interpretation and build the query — do NOT bail with null.
      - Only set module_key to null when the question truly can't map to any available module. In that case, set explanation to what you would need to answer it (e.g., "I need a module to query — try asking about leads, deals, invoices, or inventory.").
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
      raise AiError, "Claude API error: #{response.code} — #{response.body&.slice(0, 200)}"
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
      }
    else
      nil
    end

    { query_params: query_params, explanation: explanation }
  rescue JSON::ParserError => e
    raise AiError, "Could not parse Claude response as JSON: #{e.message}"
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
