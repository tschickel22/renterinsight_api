class AiActionService
  class AiError < StandardError; end

  MODEL = AiModel.for(:classification)
  MAX_TOKENS = 1500

  INTENT_READ    = 'read'
  INTENT_WRITE   = 'write'
  INTENT_CONFIRM = 'confirm'
  INTENT_DRAFT   = 'draft'
  INTENT_UNKNOWN = 'unknown'

  SAFE_ACTIONS = %w[
    create_lead
    create_activity
    add_note
  ].freeze

  CONFIRM_ACTIONS = %w[
    update_lead_status
    update_deal_stage
    update_deal_value
    assign_lead
    create_service_ticket
  ].freeze

  DRAFT_ACTIONS = %w[
    draft_email
    draft_note
    summarize_record
  ].freeze

  def initialize(api_key)
    @api_key = api_key
  end

  def classify(message, context = {})
    prompt = build_classification_prompt(message, context)
    started_at = Time.current
    response = call_claude(prompt)
    elapsed_ms = ((Time.current - started_at) * 1000).to_i
    parsed = parse_classification(response)
    parsed.merge(
      input_tokens: response.dig('usage', 'input_tokens').to_i,
      output_tokens: response.dig('usage', 'output_tokens').to_i,
      cost_cents: calculate_cost_cents(response.dig('usage', 'input_tokens').to_i, response.dig('usage', 'output_tokens').to_i),
      response_time_ms: elapsed_ms
    )
  end

  private

  def build_classification_prompt(message, context)
    today          = context[:today]            || Date.current.to_s
    company_name   = context[:company_name]     || 'the company'
    user_name      = context[:current_user_name]|| 'the user'
    sources        = context[:sources]          || []
    users          = context[:users]            || []
    page_entity_type = context[:page_entity_type]
    page_entity_id   = context[:page_entity_id]

    sources_list = sources.map { |s| "#{s[:id]}: #{s[:name]}" }.join(', ')
    users_list   = users.map  { |u| "#{u[:id]}: #{u[:name]}" }.join(', ')

    # Build current page context hint for Claude
    page_context_hint = if page_entity_type.present? && page_entity_id.present?
      "The user is currently viewing a #{page_entity_type} detail page (ID: #{page_entity_id}). " \
      "When the user refers to a person, contact, or record without specifying type, " \
      "default entity_type to \"#{page_entity_type}\" and entity_id to #{page_entity_id} unless the user clearly means something else."
    elsif page_entity_type.present?
      "The user is currently on a #{page_entity_type} page. Default entity_type to \"#{page_entity_type}\" when unclear."
    else
      nil
    end

    <<~PROMPT
      You are an AI assistant for #{company_name}, a manufactured housing and RV dealership.
      Today is #{today}. The logged-in user is #{user_name}.

      Available lead sources (id: name): #{sources_list.presence || 'none loaded'}
      Available users/staff (id: name): #{users_list.presence || 'none loaded'}

      #{page_context_hint}

      The user says: "#{message}"

      Classify the intent and extract structured params. Respond with ONLY a JSON object:

      For CREATE LEAD:
      {
        "intent": "write",
        "action": "create_lead",
        "requires_confirmation": false,
        "explanation": "Creating a new lead for John Smith",
        "params": {
          "first_name": "John",
          "last_name": "Smith",
          "phone": "260-555-1234",
          "email": "john@example.com",
          "status": "new",
          "source_id": null,
          "notes": "Interested in 3BR manufactured home",
          "interest": "3 bedroom manufactured home",
          "due_in_days": 14
        }
      }

      For CREATE CONTACT (use when user says "add contact", "new contact", "create contact" — NOT a lead):
      {
        "intent": "write",
        "action": "create_contact",
        "requires_confirmation": false,
        "explanation": "Creating a new contact for Jane Doe",
        "params": {
          "first_name": "Jane",
          "last_name": "Doe",
          "email": "jane@example.com",
          "phone": "260-555-5678",
          "notes": "Sales contact at ABC Corp"
        }
      }

      For UPDATE LEAD STATUS:
      {
        "intent": "confirm",
        "action": "update_lead_status",
        "requires_confirmation": true,
        "explanation": "Mark lead #42 as qualified",
        "params": { "lead_id": 42, "status": "qualified" }
      }

      For UPDATE DEAL STAGE:
      {
        "intent": "confirm",
        "action": "update_deal_stage",
        "requires_confirmation": true,
        "explanation": "Mark deal D-000042 as won at $89,500",
        "params": { "deal_number": "D-000042", "stage": "closed_won", "selling_price": 89500 }
      }

      For ASSIGN LEAD:
      {
        "intent": "confirm",
        "action": "assign_lead",
        "requires_confirmation": true,
        "explanation": "Assign lead #15 to Josh",
        "params": { "lead_id": 15, "owner_id": 3 }
      }

      For CREATE SERVICE TICKET:
      {
        "intent": "confirm",
        "action": "create_service_ticket",
        "requires_confirmation": true,
        "explanation": "Open a high priority ticket for AC not working",
        "params": {
          "title": "AC not working",
          "description": "Customer reports AC unit not cooling",
          "priority": "high",
          "status": "open"
        }
      }

      For CREATE ACTIVITY / LOG CALL:
      {
        "intent": "write",
        "action": "create_activity",
        "requires_confirmation": false,
        "explanation": "Log a call with Sarah Johnson",
        "params": {
          "entity_type": "lead",
          "entity_id": null,
          "entity_name": "Sarah Johnson",
          "activity_type": "call",
          "subject": "Call with Sarah Johnson",
          "notes": "Discussed financing options",
          "status": "completed",
          "priority": "medium"
        }
      }

      For ADD NOTE (e.g. "add a note to Billy Bass to follow up in 2 weeks"):
      {
        "intent": "write",
        "action": "create_activity",
        "requires_confirmation": false,
        "explanation": "Adding a follow-up task for Billy Bass due in 2 weeks",
        "params": {
          "entity_type": "lead",
          "entity_id": null,
          "entity_name": "Billy Bass",
          "activity_type": "task",
          "subject": "Follow up with Billy Bass in 2 weeks",
          "notes": "Follow up in 2 weeks",
          "status": "pending",
          "priority": "medium",
          "due_in_days": 14
        }
      }

      For DRAFT EMAIL:
      {
        "intent": "draft",
        "action": "draft_email",
        "requires_confirmation": false,
        "explanation": "Drafting follow-up email for Sarah Johnson",
        "params": {
          "recipient_name": "Sarah Johnson",
          "context": "Lead interested in 3BR manufactured home, discussed financing",
          "tone": "professional",
          "purpose": "follow_up"
        }
      }

      For READ/REPORT queries ("show me", "who is", "how many", "list all"):
      {
        "intent": "read",
        "action": "report_query",
        "requires_confirmation": false,
        "explanation": "Query handled by report engine",
        "params": {}
      }

      For SUMMARIZE a record:
      {
        "intent": "draft",
        "action": "summarize_record",
        "requires_confirmation": false,
        "explanation": "Summarizing deal history",
        "params": { "entity_type": "deal", "entity_identifier": "D-000042" }
      }

      Rules:
      - Lead statuses: new, contacted, qualified, engaged, showing_scheduled, application_submitted, closed_lost
      - Deal stages: prospecting, qualification, needs_analysis, proposal, negotiation, closing, closed_won, closed_lost
      - Service ticket priorities: low, medium, high, urgent
      - Activity types (EXACT values only): task, meeting, call, reminder, note
        - Use 'note' for: add note, log note, note that, add comment
        - Use 'task' for: add task, follow up, todo, remind me to, need to
        - Use 'call' for: log call, called, phone call, spoke with
        - Use 'meeting' for: meeting, appointment, met with
        - Use 'reminder' for: set reminder, remind, alert me
      - Activity statuses (EXACT values only): pending, in_progress, completed, cancelled
        - Use 'completed' for past actions: called, logged, met, spoke
        - Use 'pending' for future actions: follow up, remind, schedule, need to
      - Activity priorities (EXACT values only): low, medium, high, urgent
      - Time expressions — extract as due_in_days (integer, days from today):
        - "tomorrow" → 1
        - "in 2 days", "2 days" → 2
        - "next week", "in a week", "1 week" → 7
        - "in 2 weeks", "2 weeks" → 14
        - "in 3 weeks" → 21
        - "next month", "in a month" → 30
        - "in X days/weeks/months" → calculate integer days
        - If no time mentioned, omit due_in_days entirely
      - If source name matches (case-insensitive), include source_id
      - If user/staff name matches, include owner_id
      - If entity ID or number is mentioned, include it; otherwise set to null
      - Omit fields you cannot extract — do not guess email or phone
      - For ambiguous intent, prefer "read" over "write"
      - CRITICAL entity type distinction:
        - "lead" = prospective buyer/customer in the sales pipeline (use create_lead)
        - "contact" = a person associated with an account, not in the sales pipeline (use create_contact)
        - Never create a lead when the user says "contact" and vice versa
    PROMPT
  end

  def parse_classification(response)
    content = response.dig('content', 0, 'text')
    raise AiError, 'Empty response from Claude' if content.blank?
    parsed = JSON.parse(content.gsub(/```json|```/, '').strip)
    {
      intent:               parsed['intent']       || INTENT_UNKNOWN,
      action:               parsed['action']       || 'unknown',
      requires_confirmation: parsed['requires_confirmation'] != false,
      explanation:          parsed['explanation']  || '',
      params:               parsed['params']       || {}
    }
  rescue JSON::ParserError => e
    raise AiError, "Could not parse Claude response: #{e.message}"
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

  def calculate_cost_cents(input_tokens, output_tokens)
    (((input_tokens * 0.000003) + (output_tokens * 0.000015)) * 100).ceil
  end
end
