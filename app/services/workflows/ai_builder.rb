module Workflows
  class AiBuilder
    class GenerationError < StandardError; end
    class CreditLimitError < StandardError; end

    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    GENERATE_MODEL = 'claude-sonnet-4-6'
    REFINE_MODEL = 'claude-haiku-4-5-20251001'
    GENERATE_MAX_TOKENS = 4096
    REFINE_MAX_TOKENS = 2048

    DEFAULT_MONTHLY_CREDIT = 50

    ENTITY_TYPES = %w[Lead Deal Contact Account ServiceTicket Invoice Quote Vehicle].freeze

    TRIGGER_EVENT_TYPES = %w[
      lead.created lead.updated lead.status_changed lead.deleted
      deal.created deal.updated deal.status_changed deal.deleted
      contact.created contact.updated contact.status_changed contact.deleted
      account.created account.updated account.status_changed account.deleted
      service_ticket.created service_ticket.updated service_ticket.status_changed
      lead_activity.created lead_activity.updated lead_activity.completed
      deal_activity.created deal_activity.updated deal_activity.completed
      contact_activity.created contact_activity.updated contact_activity.completed
      account_activity.created account_activity.updated account_activity.completed
      inbound.webhook cron.minutely cron.hourly cron.daily cron.weekly
    ].freeze

    STEP_TYPES = %w[
      send_email send_sms wait branch update_field create_activity
      add_tag remove_tag assign_owner enroll_in_nurture halt_nurture
      call_webhook require_approval wait_for_reply score_entity classify_reply
    ].freeze

    def initialize(company:, user:, location: nil)
      @company = company
      @user = user
      @location = location
    end

    def generate(prompt:, context_overrides: {})
      check_credit!

      context = build_context(context_overrides)
      system_prompt = system_prompt_for(:generate)
      user_message = "#{prompt}\n\nContext:\n#{context.to_json}"

      response = call_claude(
        system_prompt: system_prompt, user_message: user_message,
        model: GENERATE_MODEL, max_tokens: GENERATE_MAX_TOKENS
      )

      plan = parse_plan(response[:text])
      log = log_usage(prompt, response, 'ai_workflow_generate', plan_id: nil)

      WorkflowAiGeneration.create!(
        company: @company, user: @user,
        prompt: prompt,
        context_snapshot: context,
        generated_plan: plan,
        status: 'generated',
        model_version: GENERATE_MODEL,
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        ai_query_log_id: log&.id
      )
    end

    def refine(generation:, feedback:)
      check_credit!

      system_prompt = system_prompt_for(:refine)
      user_message = <<~MSG
        Existing plan: #{generation.generated_plan.to_json}

        Feedback: #{feedback}

        Return the COMPLETE updated plan in the same JSON shape.
      MSG

      response = call_claude(
        system_prompt: system_prompt, user_message: user_message,
        model: REFINE_MODEL, max_tokens: REFINE_MAX_TOKENS
      )

      plan = parse_plan(response[:text])
      log = log_usage(feedback, response, 'ai_workflow_refine', plan_id: generation.id)

      WorkflowAiGeneration.create!(
        company: @company, user: @user,
        prompt: feedback,
        context_snapshot: generation.context_snapshot,
        generated_plan: plan,
        status: 'refined',
        parent_generation_id: generation.id,
        model_version: REFINE_MODEL,
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        ai_query_log_id: log&.id
      )
    end

    def accept(generation:)
      plan = generation.generated_plan
      rule = nil
      ActiveRecord::Base.transaction do
        rule = @company.workflow_rules.create!(
          name: plan['name'].presence || "AI Workflow #{Time.current.strftime('%b %-d')}",
          description: plan['description'],
          entity_type: plan['entity_type'].presence || 'Lead',
          status: 'draft',
          trigger: plan['trigger'] || {},
          conditions: plan['conditions'] || [],
          steps: plan['steps'] || { 'nodes' => [], 'edges' => [] },
          halt_on_reply: plan['halt_on_reply'].presence || 'false',
          created_by_user_id: @user.id
        )

        generation.update!(status: 'accepted', workflow_rule_id: rule.id)
      end
      rule
    end

    private

    def check_credit!
      limit = (ENV['AI_WORKFLOW_MONTHLY_CREDIT'] || DEFAULT_MONTHLY_CREDIT).to_i
      return if limit <= 0
      used = AiQueryLog.where(company_id: @company.id, feature: %w[ai_workflow_generate ai_workflow_refine])
                       .where('created_at >= ?', Time.current.beginning_of_month).count
      if used >= limit
        raise CreditLimitError, "Monthly AI credit limit reached (#{limit}). Upgrade your plan or contact support."
      end
    end

    def build_context(overrides)
      profile = Setting.get('Company', @company.id, 'company_profile') || {}

      base = {
        'company' => {
          'name' => @company.name,
          'display_name' => business_display_name,
          'vertical' => detect_vertical,
          'business_description' => profile['business_description'],
          'target_audience' => profile['target_audience'],
          'products_services' => profile['products_services'],
          'unique_value_props' => profile['unique_value_props'],
          'industry_vertical' => profile['industry_vertical'],
          'brand_voice' => profile['brand_voice']
        }.compact,
        'sender' => sender_context_hash,
        'entity_types' => ENTITY_TYPES,
        'trigger_event_types' => TRIGGER_EVENT_TYPES,
        'step_types' => STEP_TYPES,
        'existing_rule_names' => safe_pluck(@company.try(:workflow_rules), :name).first(50),
        'merge_tags_by_entity' => merge_tags_summary,
        # Company-specific custom fields so the model uses field_key snake_case
        # (e.g. "next_appointment") in update_field configs instead of the
        # human-readable name ("Next Appointment"), which crashes at run time.
        'custom_fields_by_entity' => custom_fields_context
      }
      base.merge((overrides || {}).stringify_keys)
    end

    # Snapshot of the company's active custom fields grouped by entity, keyed
    # to the shape the update_field step expects.
    def custom_fields_context
      return {} unless defined?(CustomField)
      CustomField
        .where(company_id: @company.id, is_active: true)
        .pluck(:module, :field_key, :name, :field_type)
        .group_by(&:first)
        .transform_values do |rows|
          rows.map { |(_, field_key, name, field_type)| { 'field_key' => field_key, 'name' => name, 'field_type' => field_type } }
        end
    rescue
      {}
    end

    def sender_context_hash
      return {} unless @user
      {
        'full_name' => [@user.try(:first_name), @user.try(:last_name)].compact.join(' ').strip,
        'title' => @user.try(:title).to_s.strip,
        'phone' => @user.try(:phone).to_s.strip,
        'signature' => @user.try(:typed_signature).to_s.strip,
        'booking_url' => @user.try(:booking_url).to_s.strip
      }.reject { |_, v| v.blank? }
    end

    def business_display_name
      loc_name = @location&.name.to_s.strip
      return loc_name if loc_name.present? && loc_name.downcase != 'main'
      @company.name
    end

    def safe_pluck(rel, column)
      rel.respond_to?(:pluck) ? rel.pluck(column).compact : []
    rescue
      []
    end

    def detect_vertical
      return 'universal' unless @company.respond_to?(:vehicles)
      types = @company.vehicles.distinct.pluck(:listing_type).compact
      return 'manufactured_home' if types.include?('mh')
      return 'rv' if types.include?('rv')
      'universal'
    rescue
      'universal'
    end

    def merge_tags_summary
      WorkflowFieldMetadata::SUPPORTED_TYPES.each_with_object({}) do |type, acc|
        data = WorkflowFieldMetadata.for(type)
        acc[type] = data[:merge_tags].map { |t| t[:key] }
      rescue ArgumentError
        next
      end
    rescue
      {}
    end

    def system_prompt_for(mode)
      base = <<~SYS
        You are an expert workflow automation designer for RenterInsight, a Dealer Management System (DMS) used by manufactured home and RV dealers. You help dealers build automated workflows that fire when something happens to a Lead, Deal, Contact, Account, Quote, Invoice, Service Ticket, or Vehicle.

        OUTPUT RULES:
        - You MUST respond with a single JSON object, nothing else. No prose, no markdown, no explanation.
        - The JSON shape:
          {
            "name": "Short workflow name",
            "description": "One-sentence summary",
            "entity_type": "Lead" | "Deal" | "Contact" | "Account" | "ServiceTicket" | "Invoice" | "Quote" | "Vehicle",
            "trigger": { "event_type": "<one of the trigger event types>", "entity_type_filter": null },
            "conditions": { "logic": "and"|"or", "conditions": [{ "field": "...", "operator": "equals|not_equals|contains|in|gt|lt|gte|lte|is_set|is_not_set", "value": ... }] } | null,
            "halt_on_reply": "false" | "true" | "branch",
            "steps": {
              "nodes": [
                { "id": "step_1", "type": "<step type>", "config": { ... } }
              ],
              "edges": [
                { "source": "step_1", "target": "step_2" }
              ]
            } | null,
            "questions": [ "string", ... ] | null
          }

        QUESTIONS FIELD (CRITICAL):
        - If the user's prompt is ambiguous in a way that prevents you from confidently choosing entity_type, trigger, or actions, return 1-3 clarifying questions in "questions" and set "steps" to null.
        - Be CONSERVATIVE. Most prompts have enough information; don't ask unless you really cannot decide. Examples:
          - "build me an automation" → ambiguous, ask what entity and what should happen.
          - "email leads from Champion" → clear: entity=Lead, trigger=lead.created, condition source equals Champion Leads, step=send_email.
          - "when a deal closes notify the team" → mostly clear but "notify" is ambiguous (email vs SMS vs who) — ask 1 question.
        - If the prompt is clear, set "questions" to null and produce full "steps".

        ENTITY TYPES: Lead, Deal, Contact, Account, ServiceTicket, Invoice, Quote, Vehicle.

        TRIGGER EVENT TYPES (use the EXACT string in trigger.event_type):
        - lead.created, lead.updated, lead.status_changed, lead.deleted
        - deal.created, deal.updated, deal.status_changed, deal.deleted
        - contact.created, contact.updated, contact.status_changed, contact.deleted
        - account.created, account.updated, account.status_changed, account.deleted
        - service_ticket.created, service_ticket.updated, service_ticket.status_changed
        - lead_activity.created / updated / completed — fires when an activity is added/edited/completed on a lead.
          The workflow runs on the PARENT lead; the activity is exposed as {{activity.due_date}}, {{activity.subject}}, {{activity.status}}, etc.
          Use this for "when a lead gets a new activity/task/meeting with a due date, update the lead". Analogous:
          deal_activity.*, contact_activity.*, account_activity.*.
        - inbound.webhook (use for "when a form is submitted" or external HTTP triggers)
        - cron.minutely, cron.hourly, cron.daily, cron.weekly (use for time-based workflows like "every Monday")

        STEP TYPES (16 total). Each node has { id, type, config }. `config` must match the type's schema below:

        1) send_email
           config: { "to": "{{entity.email}}", "subject": "...", "body": "<p>HTML body</p>" }
           - "to" defaults to "{{entity.email}}" unless emailing someone else (e.g. owner: "{{entity.owner_email}}").
           - "body" MUST be HTML.

        2) send_sms
           config: { "to": "{{entity.phone}}", "body": "Plain text SMS" }
           - "body" is plain text, no HTML. Keep under 1500 chars. Do not include "Reply STOP" — system appends it.

        3) wait
           config: { "duration": <number >= 1>, "unit": "minutes"|"hours"|"days" }

        4) branch
           config: { "condition": "entity.status == \\"qualified\\"", "on_true_branch": "step_X", "on_false_branch": "step_Y" }
           - Condition is a JS-like expression on `entity.<field>`. For branch nodes, include on_true_branch/on_false_branch in config pointing at target node ids (also add corresponding edges).

        5) update_field
           config: { "fields": { "status": "contacted", "priority": "high" } }
           - Field keys MUST be the snake_case column name or custom_field field_key.
             NEVER use the display name. Example: use "next_appointment" NOT "Next Appointment".
             Custom fields for the current company are listed in the "Custom Fields" section
             of the CONTEXT — use the field_key column verbatim.

        6) create_activity
           config: { "activity_type": "task"|"call"|"email"|"meeting"|"note"|"reminder", "subject": "...", "description": "...", "due_in_days": 1, "assigned_to_user_id": null }

        7) add_tag
           config: { "tag_names": ["hot-lead", "champion"] }

        8) remove_tag
           config: { "tag_names": ["cold"] }

        9) assign_owner
           config: { "strategy": "specific_user"|"round_robin"|"load_balanced", "user_id": 123 }
           - user_id is required when strategy is "specific_user".

        10) enroll_in_nurture
            config: { "nurture_sequence_id": 42 }

        11) halt_nurture
            config: { "nurture_sequence_id": 42 }
            - Leave nurture_sequence_id blank to halt ALL nurtures for the entity.

        12) call_webhook
            config: { "url": "https://...", "method": "POST", "headers": {}, "body": {} }

        13) require_approval
            config: { "approver_user_id": 123 }

        14) wait_for_reply
            config: { "timeout_hours": <number >= 1> }

        15) score_entity
            config: { "score_field": "lead_score", "prompt": "Score this lead 0-100 based on..." }

        16) classify_reply
            config: { "categories": ["positive", "negative", "neutral"], "write_to_variable": "reply_classification" }

        NODE IDS & EDGES:
        - Node ids MUST be "step_1", "step_2", ... in document order (no gaps).
        - Edges connect nodes linearly by default: [{ source: "step_1", target: "step_2" }, ...]
        - For "branch" nodes, also set on_true_branch / on_false_branch in config to the target node ids and add explicit edges for each branch path.

        MERGE TAGS (use in send_email subject/body, send_sms body, create_activity, update_field values):
        - {{entity.first_name}}, {{entity.last_name}}, {{entity.full_name}}
        - {{entity.email}}, {{entity.phone}}
        - {{entity.status}}, {{entity.source}}
        - {{entity.owner_name}}, {{entity.owner_email}}, {{entity.owner_phone}}
        - {{entity.account_name}} (Lead/Deal/Contact)
        - {{entity.assigned_to_name}} (ServiceTicket)
        - {{company.name}}, {{company.phone}}, {{company.email}}
        - {{current_user.name}}, {{current_user.email}}, {{current_date}}
        Entity-specific tags exist for Deal (entity.name, entity.stage, entity.amount, entity.expected_close_date), ServiceTicket (entity.ticket_number, entity.title, entity.priority), Home (home.year, home.make, home.model, home.sale_price), Listing (listing.property_name, listing.url).

        CONDITIONS:
        - Top-level "conditions" gate whether the workflow fires on the triggering entity.
        - Shape: { "logic": "and"|"or", "conditions": [{ "field": "source", "operator": "equals", "value": "Champion Leads" }] }
        - Use null for "conditions" if no gating is needed.

        HALT_ON_REPLY:
        - "false" (default) — workflow keeps running even if entity replies.
        - "true" — cancel the run on any inbound reply.
        - "branch" — sets reply_received=true variable so a branch node can route differently.

        VOICE (for email/SMS bodies in send_email / send_sms / create_activity steps):
        - Direct, specific to MH/RV dealer industry where relevant. No "I hope this email finds you well".
        - Reference real pain points: lost leads, spreadsheet chaos, AR aging, factory wait times, walk-ins.
        - Match the brand voice from context.company.brand_voice when set; lean on context.company.business_description / target_audience / unique_value_props for what to say.
        - When referring to the sender's own business in copy, use context.company.display_name (NOT {{company.name}}, which refers to the platform's company record).
        - Never use placeholders like "[Your name]". If context.sender.signature is present, use it verbatim at the end of email bodies. Otherwise build a sign-off from context.sender.full_name + title + phone + display_name (omit blank pieces, but display_name MUST be in the sign-off — that's how the recipient knows who's reaching out). SMS = first name only.
        - If context.sender.booking_url is present and an action's natural CTA is to schedule / demo / tour / talk live: for send_email actions, render as HTML — `<a href="booking_url">Book here</a>` inside a body wrapped in `<p>` tags so the mail renderer treats it as HTML. For send_sms, include the raw URL with framing like "Book a time:". Don't shove it into unrelated steps.
      SYS

      mode == :refine ? base + "\n\nThe user is iterating on a previous plan. Apply their feedback and return the COMPLETE updated plan in the same JSON shape." : base
    end

    def call_claude(system_prompt:, user_message:, model:, max_tokens:)
      api_key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
      raise GenerationError, 'Anthropic API key not configured' if api_key.blank?

      uri = URI(CLAUDE_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 120
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = {
        model: model,
        max_tokens: max_tokens,
        system: system_prompt,
        messages: [{ role: 'user', content: user_message }]
      }.to_json

      response = http.request(request)

      unless response.code.to_s == '200'
        body = JSON.parse(response.body) rescue {}
        raise GenerationError, "Claude API error: #{body.dig('error', 'message') || response.code}"
      end

      result = JSON.parse(response.body)
      text = result['content']&.find { |c| c['type'] == 'text' }&.fetch('text', '')
      usage = result['usage'] || {}

      {
        text: text,
        input_tokens: usage['input_tokens'],
        output_tokens: usage['output_tokens']
      }
    end

    def parse_plan(text)
      cleaned = text.to_s.strip
      cleaned = cleaned.gsub(/\A```(?:json)?\s*/, '').gsub(/\s*```\z/, '')
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      raise GenerationError, "AI returned invalid JSON: #{e.message[0, 200]}"
    end

    def log_usage(prompt_text, response, feature, plan_id:)
      cost_cents = compute_cost(response[:input_tokens].to_i, response[:output_tokens].to_i, feature)
      AiQueryLog.create!(
        company: @company, user: @user,
        feature: feature,
        module_key: 'workflows',
        question: prompt_text.to_s[0, 1000],
        generated_params: { plan_id: plan_id },
        execution_status: 'success',
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        cost_cents: cost_cents
      )
    rescue => e
      Rails.logger.error "[Workflows::AiBuilder] AiQueryLog create failed: #{e.message}"
      nil
    end

    # Sonnet 4: $3/MTok in, $15/MTok out. Haiku 4.5: $0.25/MTok in, $1.25/MTok out.
    # cost_cents = tokens * (price_per_1M / 10_000)
    def compute_cost(input_tokens, output_tokens, feature)
      cents = if feature == 'ai_workflow_generate'
                (input_tokens * 3.0 + output_tokens * 15.0) / 10_000.0
              else
                (input_tokens * 0.25 + output_tokens * 1.25) / 10_000.0
              end
      cents.round
    end
  end
end
