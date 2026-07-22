class AiDraftService
  class AiError < StandardError; end

  MODEL = AiModel.for(:generation)
  MAX_TOKENS = 800

  def initialize(api_key)
    @api_key = api_key
  end

  def generate(action, params, context = {})
    prompt = case action
    when 'draft_email'      then email_prompt(params, context)
    when 'summarize_record' then summary_prompt(params, context)
    when 'draft_note'       then note_prompt(params, context)
    else
      raise AiError, "Unknown draft action: #{action}"
    end

    response = call_claude(prompt)
    content = response.dig('content', 0, 'text')&.strip

    {
      content: content,
      input_tokens:  response.dig('usage', 'input_tokens').to_i,
      output_tokens: response.dig('usage', 'output_tokens').to_i,
      cost_cents: ((response.dig('usage', 'input_tokens').to_i * 0.000003 +
                    response.dig('usage', 'output_tokens').to_i * 0.000015) * 100).ceil
    }
  end

  private

  def email_prompt(params, context)
    company = context[:company_name] || 'our dealership'
    <<~PROMPT
      Write a #{params['tone'] || 'professional'} #{params['purpose'] || 'follow-up'} email
      for #{company} to #{params['recipient_name']}.
      Context: #{params['context']}
      - Keep it concise (3-4 short paragraphs max)
      - Manufactured housing/RV dealership tone
      - Include subject line as first line prefixed with "Subject: "
      - Do not include placeholder brackets like [Name] — use the actual name provided
    PROMPT
  end

  def summary_prompt(params, context)
    record_data = context[:record_data] || 'No data provided'
    <<~PROMPT
      Summarize this #{params['entity_type']} record in 2-3 sentences for a dealership manager.
      Focus on: current status, key dates, value, and any action needed.
      Record data: #{record_data.to_json}
    PROMPT
  end

  def note_prompt(params, context)
    "Write a brief professional CRM note about: #{params['context']}. Keep it under 3 sentences."
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
    raise AiError, "Claude API error: #{response.code}" unless response.code == '200'
    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise AiError, "Timeout: #{e.message}"
  end
end
