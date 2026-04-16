class ReportAiService
  class AiError < StandardError; end
  class RateLimitError < StandardError; end

  MODEL = 'claude-sonnet-4-20250514'
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

      Respond with ONLY a JSON object (no markdown, no explanation outside JSON):
      {
        "module_key": "leads",
        "fields": ["id", "first_name", "last_name", "status", "created_at"],
        "filters": {
          "date_range": { "field": "created_at", "from": "2026-03-01", "to": "2026-04-06" },
          "where": [{ "field": "stage", "operator": "eq", "value": "closed_won" }]
        },
        "sort_by": "created_at",
        "sort_order": "desc",
        "explanation": "Showing closed won deals from the past 7 days, sorted newest first."
      }

      Rules:
      - Only use fields that exist in the modules_summary above
      - If date range is implied (e.g., "this week", "past 7 days", "this month"), calculate exact dates from today
      - If the question is ambiguous, pick the most reasonable interpretation
      - Set explanation to a single clear sentence describing what the report will show
      - If a question cannot be answered with the available modules/fields, set module_key to null and explanation to why
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
