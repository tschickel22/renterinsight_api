module Campaigns
  class AiBuilder
    class GenerationError < StandardError; end
    class CreditLimitError < StandardError; end

    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    GENERATE_MODEL = 'claude-sonnet-4-6'
    REFINE_MODEL = 'claude-haiku-4-5-20251001'
    GENERATE_MAX_TOKENS = 4096
    REFINE_MAX_TOKENS = 2048

    DEFAULT_MONTHLY_CREDIT = 50

    def initialize(company:, user:, location: nil)
      @company = company
      @user = user
      @location = location
    end

    def generate(prompt:, channel: 'email', context_overrides: {}, attachment_context: [])
      check_credit!

      context = build_context(channel, context_overrides)
      system_prompt = system_prompt_for(:generate)

      # Build user message with optional document context
      user_parts = ["#{prompt}\n\nContext:\n#{context.to_json}"]
      if attachment_context.is_a?(Array) && attachment_context.any?
        doc_summaries = attachment_context.map { |a| "[Document: #{a['filename']}]\n#{decode_base64_text(a['data_base64'])}" }.join("\n\n")
        user_parts << "\n\nAttached documents for reference — use their content to inform the campaign copy:\n#{doc_summaries}"
      end
      user_message = user_parts.join

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

    def refine(generation:, feedback:, attachment_context: [])
      check_credit!

      channel = generation.generated_plan['channel'] || 'email'
      system_prompt = system_prompt_for(:refine)

      # Include document context in refine so AI retains knowledge of uploaded docs
      doc_section = ''
      if attachment_context.is_a?(Array) && attachment_context.any?
        doc_summaries = attachment_context.map { |a| "[Document: #{a['filename']}]\n#{decode_base64_text(a['data_base64'])}" }.join("\n\n")
        doc_section = "\n\nUploaded documents for reference:\n#{doc_summaries}"
      end

      user_message = <<~MSG
        Existing plan: #{generation.generated_plan.to_json}

        Company context: #{generation.context_snapshot.to_json}

        Feedback: #{feedback}#{doc_section}

        Return the COMPLETE updated plan in the same JSON shape. ALWAYS include steps — never return steps as null.
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

    def accept(generation:, sender_params:, plan_override: nil)
      plan = plan_override.present? ? plan_override.deep_stringify_keys : generation.generated_plan
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
          additional_source_types: Array(audience['additional_source_types']).map(&:to_s).reject(&:blank?),
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
      # Try both casings for the setting key (historically inconsistent)
      profile = Setting.get('Company', @company.id, 'company_profile') ||
                Setting.get('company', @company.id, 'company_profile') || {}

      # Also pull from company model columns directly as fallback
      company_hash = {
        'name' => @company.name,
        'display_name' => business_display_name,
        'vertical' => detect_vertical,
        'business_description' => profile['business_description'].presence || @company.try(:description).to_s.presence,
        'target_audience' => profile['target_audience'],
        'products_services' => profile['products_services'],
        'unique_value_props' => profile['unique_value_props'],
        'industry_vertical' => profile['industry_vertical'],
        'brand_voice' => profile['brand_voice'],
        'website' => @company.try(:website).to_s.presence,
        'phone' => @company.try(:phone).to_s.presence,
        'email' => @company.try(:email).to_s.presence,
        'address' => [@company.try(:address), @company.try(:city), @company.try(:state), @company.try(:zip)].compact.join(', ').presence
      }.compact

      base = {
        'company' => company_hash,
        'sender' => sender_context_hash,
        'channel' => channel,
        'inventory_summary' => inventory_summary,
        'lead_count' => safe_count(@company.try(:leads)),
        'contact_count' => safe_count(@company.try(:contacts)),
        'available_templates' => CampaignTemplate.seeded.where(channel: channel).pluck(:slug)
      }
      base.merge((overrides || {}).stringify_keys)
    end

    def business_display_name
      loc_name = @location&.name.to_s.strip
      return loc_name if loc_name.present? && loc_name.downcase != 'main'
      @company.name
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

    # Build a rich sender context block for the system prompt (ported from nurture AI builder)
    def sender_context_block
      sender = sender_context_hash
      biz_name = business_display_name
      return '' if sender.blank? && biz_name.blank?

      lines = []
      if sender['signature'].present?
        lines << "Sender's email signature (use this verbatim at the end of email bodies):"
        lines << sender['signature']
      elsif sender['full_name'].present?
        lines << '  - Build a sign-off at the bottom of email bodies, in this order (omit blank fields, but always end with the business name):'
        lines << "      Name: #{sender['full_name']}"
        lines << "      Title: #{sender['title']}" if sender['title'].present?
        lines << "      Phone: #{sender['phone']}" if sender['phone'].present?
        lines << "      Business: #{biz_name}" if biz_name.present?
      end
      if sender['booking_url'].present?
        lines << ''
        lines << "Sender's booking link: #{sender['booking_url']}"
        lines << '  - For EMAIL: render as HTML anchor with short link text — <a href="URL">Book here</a>. Do NOT expose the raw URL.'
        lines << '  - For SMS: include the raw URL with framing text.'
        lines << "  - Don't include the booking link in every step — only where it's the right CTA."
      end
      return '' if lines.empty?
      "\nSENDER CONTEXT:\n#{lines.join("\n")}\n"
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
      profile = Setting.get('Company', @company.id, 'company_profile') ||
                Setting.get('company', @company.id, 'company_profile') || {}

      base = <<~SYS
        You are an expert email/SMS marketing strategist for RenterInsight, a Dealer Management System used by manufactured home and RV dealers. You help dealers build campaigns to either (a) sell DMS to other dealers (B2B) or (b) sell homes/RVs to buyers (B2C).

        BUSINESS CONTEXT:
        Business name: #{business_display_name}
        #{profile['business_description'].present? ? "About: #{profile['business_description']}" : ''}
        #{profile['target_audience'].present? ? "Target audience: #{profile['target_audience']}" : ''}
        #{profile['products_services'].present? ? "Products/services: #{profile['products_services']}" : ''}
        #{profile['unique_value_props'].present? ? "Value proposition: #{profile['unique_value_props']}" : ''}
        Industry: #{profile['industry_vertical'] || 'general'}
        Brand voice: #{profile['brand_voice'] || 'professional'}
        #{sender_context_block}

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
              "additional_source_types": ["Lead" | "Contact" | "Account"],  // OPTIONAL; extra entity types to enroll with the SAME filter (dedupe by email). Use when the prompt says "leads and contacts", "customers and prospects", or asks for a newsletter to a shared tag set.
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
                "inventory_block_config": null | {
                  "mode": "segment_based" | "category_based" | "manual_pick",
                  "sort": "newest" | "price_low" | "price_high" | "best_match",
                  "max_units": 3,
                  "fallback": "skip_block" | "show_cta" | "abort_send",
                  "filters": {
                    "listing_type": "...",
                    "bedrooms_min": 0,
                    "price_max": 0,
                    "location_ids": [1, 2],
                    "statuses": ["available", "available_to_order"],  // OPTIONAL admin-controlled status set. Omit for default (available + available_to_order). Include "pending" or "reserved" only if the prompt explicitly asks.
                    "require_images": true | false  // OPTIONAL; set true when the prompt implies visual quality ("only homes with photos", "showcase", "featured", "gallery").
                  }
                }
              }
            ]
          },
            "questions": ["string", ...] | null
          }

        HTML FORMATTING:
        - CRITICAL: Each paragraph MUST be wrapped in its own <p>...</p> tag
        - Do NOT put all content in a single <p> tag — separate paragraphs need separate <p> blocks
        - Sign-off should be in its own <p> tag with <br> between lines
        - Example: <p>First paragraph here.</p><p>Second paragraph about something else.</p><p>Best,<br>Tom Schickel<br>Renter Insight</p>

        QUESTIONS FIELD (CRITICAL):
        - If the user's prompt is too vague to confidently build a campaign, return 1-3 clarifying questions in "questions" and set "steps" to null.
        - Be EXTREMELY CONSERVATIVE about asking questions — ALWAYS prefer generating steps over asking.
        - If you have ANY uploaded documents or company context, you have enough to build the campaign. NEVER ask questions when documents are provided.
        - Even for vague prompts, attempt to generate steps. Only ask when you literally cannot determine the channel AND the topic.
        - Examples:
          - "send something to my leads" → ambiguous but still generate a general outreach series
          - "welcome email series for new MH leads" → clear enough, just build it
          - "blast about our sale" → generate a sale-focused campaign, assume reasonable offer details from company context
        - If the prompt is clear OR if uploaded documents are provided, set "questions" to null and produce full "steps".

        UPLOADED DOCUMENTS:
        - When documents are attached, treat them as the PRIMARY source of content for the campaign.
        - Extract key messaging, product details, pricing, features, and value propositions from the documents.
        - Weave document content naturally into email copy — don't just summarize, use it to write compelling campaign steps.
        - If the user uploaded a document, they want that content used. Always generate steps when documents are provided.
        - Reference specific details from documents (pricing, features, benefits) to make emails specific and valuable.

        VOICE:
        - Direct, specific, no "I hope this email finds you well".
        - Reference real industry pain points (spreadsheets, lost leads, AR aging, factory wait times).
        - Use merge tags: {{first_name}}, {{last_name}}, {{full_name}}, {{rep_name}}, {{rep_email}}, {{company.name}}, {{public_inventory_url}}, {{unsubscribe_url}}.
        - Match the brand voice from context.company.brand_voice when set; lean on context.company.business_description / target_audience / unique_value_props for what to say.
        - When referring to the sender's own business in copy, use context.company.display_name (NOT {{company_name}}, which is reserved for the recipient's company).
        - Never use placeholders like "[Your name]". If context.sender.signature is present, use it verbatim at the end of email bodies. Otherwise build a sign-off from context.sender.full_name + title + phone + display_name (omit blank pieces, but the business display_name MUST be in the sign-off — that's how the recipient knows who's reaching out). For SMS use first name only.
        - If context.sender.booking_url is present and the step's CTA is to schedule/demo/tour/talk live: prefer a button block `{ type: "button", text: "Book a time" | "View my calendar", href: booking_url }`. For inline links inside text blocks, use `<a href="booking_url">Book here</a>` — never expose the raw URL in email. For SMS, include the raw URL with framing text. Don't shove it into every step.

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

    # Decode base64-encoded document for AI context.
    # Handles PDFs (extracts text via pdf-reader gem), plain text, and other formats.
    # Returns first 50K chars to stay within token limits.
    def decode_base64_text(b64)
      return '' if b64.blank?
      raw = Base64.decode64(b64)

      # Detect PDF by magic bytes (%PDF)
      if raw[0, 5]&.force_encoding('ASCII-8BIT')&.start_with?('%PDF')
        extract_pdf_text(raw)
      else
        text = raw.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        text[0, 50_000]
      end
    rescue => e
      Rails.logger.warn "[Campaigns::AiBuilder] decode_base64_text failed: #{e.message}"
      ''
    end

    # Extract text from PDF binary data using pdf-reader gem.
    def extract_pdf_text(pdf_bytes)
      require 'pdf-reader'
      io = StringIO.new(pdf_bytes)
      reader = PDF::Reader.new(io)
      pages_text = reader.pages.first(30).map { |p| p.text.to_s }.join("\n\n")
      pages_text[0, 50_000]
    rescue => e
      Rails.logger.warn "[Campaigns::AiBuilder] PDF text extraction failed: #{e.message}"
      # Fallback: try raw UTF-8 extraction
      raw_text = pdf_bytes.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      raw_text.gsub(/[^\x20-\x7E\n\r\t]/, ' ').squeeze(' ')[0, 50_000]
    end
  end
end
