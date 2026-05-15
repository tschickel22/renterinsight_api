module Campaigns
  class AiBuilder
    class GenerationError < StandardError; end
    class CreditLimitError < StandardError; end

    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    GENERATE_MODEL = 'claude-sonnet-4-20250514'
    REFINE_MODEL = 'claude-haiku-4-5-20251001'
    GENERATE_MAX_TOKENS = 4096
    REFINE_MAX_TOKENS = 2048

    DEFAULT_MONTHLY_CREDIT = 50

    def initialize(company:, user:)
      @company = company
      @user = user
    end

    def generate(prompt:, channel: 'email', context_overrides: {})
      check_credit!

      context = build_context(channel, context_overrides)
      system_prompt = system_prompt_for(:generate)
      user_message = "#{prompt}\n\nContext:\n#{context.to_json}"

      response = call_claude(
        system_prompt: system_prompt, user_message: user_message,
        model: GENERATE_MODEL, max_tokens: GENERATE_MAX_TOKENS
      )

      plan = parse_plan(response[:text])
      log = log_usage(prompt, response, channel, 'ai_campaign_generate', plan_id: nil)

      CampaignAiGeneration.create!(
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

      channel = generation.generated_plan['channel'] || 'email'
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
      log = log_usage(feedback, response, channel, 'ai_campaign_refine', plan_id: generation.id)

      CampaignAiGeneration.create!(
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

    def accept(generation:, sender_params:)
      plan = generation.generated_plan
      campaign = nil
      ActiveRecord::Base.transaction do
        campaign = @company.campaigns.create!(
          name: plan['name'].presence || "AI Campaign #{Time.current.strftime('%b %-d')}",
          description: plan['description'],
          status: 'draft',
          campaign_type: plan['campaign_type'].presence || 'drip',
          audience_mode: plan['audience_mode'].presence || 'static',
          channel: plan['channel'].presence || 'email',
          from_identity_type: sender_params[:from_identity_type],
          from_identity_id: sender_params[:from_identity_id],
          from_display_name: sender_params[:from_display_name],
          goal_config: plan['goal_config'] || {},
          send_window: plan['send_window'] || {},
          utm_source: 'campaign',
          utm_medium: plan['channel'] == 'sms' ? 'sms' : 'email',
          utm_campaign: plan['name'].to_s.parameterize.presence || 'ai-generated',
          generated_from_ai_generation_id: generation.id,
          created_by_user_id: @user.id,
          location_id: sender_params[:location_id]
        )

        Array(plan['steps']).each_with_index do |step, idx|
          campaign.campaign_steps.create!(
            position: idx,
            channel: plan['channel'] || 'email',
            wait_days: step['wait_days'] || 0,
            wait_hours: step['wait_hours'] || 0,
            subject: step['subject'],
            preheader: step['preheader'],
            body_blocks: step['body_blocks'] || [],
            sms_body: step['sms_body'],
            inventory_block_config: step['inventory_block_config']
          )
        end

        audience = plan['audience'] || {}
        campaign.create_campaign_audience!(
          source_type: audience['source_type'] || 'Lead',
          filter_tree: audience['filter_tree'] || {}
        )

        generation.update!(status: 'accepted', campaign_id: campaign.id)
      end
      campaign
    end

    private

    def check_credit!
      limit = (ENV['AI_CAMPAIGN_MONTHLY_CREDIT'] || DEFAULT_MONTHLY_CREDIT).to_i
      return if limit <= 0
      used = AiQueryLog.where(company_id: @company.id, feature: %w[ai_campaign_generate ai_campaign_refine])
                       .where('created_at >= ?', Time.current.beginning_of_month).count
      if used >= limit
        raise CreditLimitError, "Monthly AI credit limit reached (#{limit}). Upgrade your plan or contact support."
      end
    end

    def build_context(channel, overrides)
      base = {
        'company' => {
          'name' => @company.name,
          'vertical' => detect_vertical
        },
        'channel' => channel,
        'inventory_summary' => inventory_summary,
        'lead_count' => safe_count(@company.try(:leads)),
        'contact_count' => safe_count(@company.try(:contacts)),
        'available_templates' => CampaignTemplate.seeded.where(channel: channel).pluck(:slug)
      }
      base.merge((overrides || {}).stringify_keys)
    end

    def safe_count(rel)
      rel.respond_to?(:count) ? rel.count : 0
    rescue
      0
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

    def inventory_summary
      return {} unless @company.respond_to?(:vehicles)
      vehicles = @company.vehicles.where(status: 'available')
      {
        'available_count' => vehicles.count,
        'price_range' => {
          'min' => vehicles.minimum(:sale_price)&.to_i,
          'max' => vehicles.maximum(:sale_price)&.to_i
        },
        'manufacturers' => vehicles.distinct.pluck(:make).compact.first(10)
      }
    rescue
      {}
    end

    def system_prompt_for(mode)
      base = <<~SYS
        You are an expert email/SMS marketing strategist for RenterInsight, a Dealer Management System used by manufactured home and RV dealers. You help dealers build campaigns to either (a) sell DMS to other dealers (B2B) or (b) sell homes/RVs to buyers (B2C).

        OUTPUT RULES:
        - You MUST respond with a single JSON object, nothing else. No prose, no markdown, no explanation.
        - The JSON shape:
          {
            "name": "Short campaign name",
            "description": "One-sentence summary",
            "campaign_type": "blast" | "drip" | "triggered" | "recurring_digest",
            "channel": "email" | "sms",
            "audience_mode": "static" | "dynamic",
            "audience": {
              "source_type": "Lead" | "Contact" | "Account",
              "filter_tree": { "type": "and", "children": [{ "field": "...", "operator": "equals|in|...", "value": ... }] }
            },
            "goal_config": { "primary_goal": "replied", "remove_on_goal_met": true, "additional_goals": [] },
            "send_window": { "business_hours_only": true },
            "steps": [
              {
                "wait_days": 0, "wait_hours": 0,
                "subject": "Email subject (omit for SMS)",
                "preheader": "Email preview text (omit for SMS)",
                "body_blocks": [
                  { "type": "text", "html": "<p>Hi {{first_name}}, ...</p>" },
                  { "type": "button", "text": "View homes", "href": "{{public_inventory_url}}" }
                ],
                "sms_body": "SMS text (SMS ONLY, max 1500 chars to leave room for STOP footer)",
                "inventory_block_config": null
              }
            ]
          },
            "questions": ["string", ...] | null
          }

        QUESTIONS FIELD (CRITICAL):
        - If the user's prompt is too vague to confidently build a campaign, return 1-3 clarifying questions in "questions" and set "steps" to null.
        - Be CONSERVATIVE — most prompts have enough to work with. Only ask when you truly cannot decide channel, audience, or what the content should say.
        - Examples:
          - "send something to my leads" → ambiguous, ask what the message should be about and what channel
          - "welcome email series for new MH leads" → clear enough, just build it
          - "blast about our sale" → mostly clear but what sale? ask 1 question about the offer details
        - If the prompt is clear, set "questions" to null and produce full "steps".

        VOICE:
        - Direct, specific, no "I hope this email finds you well".
        - Reference real industry pain points (spreadsheets, lost leads, AR aging, factory wait times).
        - Use merge tags: {{first_name}}, {{last_name}}, {{full_name}}, {{rep_name}}, {{rep_email}}, {{company.name}}, {{public_inventory_url}}, {{unsubscribe_url}}.

        CADENCE:
        - Day 1, then space subsequent steps (3, 7, 14, 30, 60 days are sensible).
        - Never less than 24 hours between steps.

        COMPLIANCE:
        - Email steps must be okay with CAN-SPAM (footer auto-added by system).
        - SMS steps must include opt-out language; "Reply STOP to unsubscribe" is auto-appended by the system, do NOT include it yourself.
        - SMS body max 1500 chars.

        VERTICAL CUES:
        - "MHI show" / "retailer" / "dealer" -> B2B selling DMS
        - "Facebook leads" / "homebuyers" / "buyers" -> B2C selling homes
        - "budget" / "preferences" -> use inventory_block with mode "segment_based"
        - "weekly digest" / "new arrivals" -> recurring_digest with inventory_block mode "category_based" or "segment_based"
      SYS

      mode == :refine ? base + "\n\nThe user is iterating on a previous plan. Apply their feedback and return the COMPLETE updated plan." : base
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

    def log_usage(prompt_text, response, channel, feature, plan_id:)
      cost_cents = compute_cost(response[:input_tokens].to_i, response[:output_tokens].to_i, feature)
      AiQueryLog.create!(
        company: @company, user: @user,
        feature: feature,
        module_key: 'campaigns',
        question: prompt_text.to_s[0, 1000],
        generated_params: { channel: channel, plan_id: plan_id },
        execution_status: 'success',
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        cost_cents: cost_cents
      )
    rescue => e
      Rails.logger.error "[Campaigns::AiBuilder] AiQueryLog create failed: #{e.message}"
      nil
    end

    # Sonnet 4: $3/MTok in, $15/MTok out. Haiku 4.5: $0.25/MTok in, $1.25/MTok out.
    # cost_cents = tokens * (price_per_1M / 10_000)
    def compute_cost(input_tokens, output_tokens, feature)
      cents = if feature == 'ai_campaign_generate'
                (input_tokens * 3.0 + output_tokens * 15.0) / 10_000.0
              else
                (input_tokens * 0.25 + output_tokens * 1.25) / 10_000.0
              end
      cents.round
    end
  end
end
