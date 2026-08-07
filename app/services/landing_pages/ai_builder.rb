# frozen_string_literal: true

require 'net/http'

module LandingPages
  # Generates landing page copy from a Marketing::Brief.
  #
  # Headless on purpose. Campaign Desk's orchestrator hands the SAME brief to
  # this, to Campaigns::AiBuilder and to the social generator, so the four
  # assets read as one campaign. A builder that owned its own prompt could not
  # be called that way, and the landing page would end up arguing with the
  # email that drove traffic to it.
  #
  # It emits profile SECTIONS, not blocks — the same contract
  # SiteProfiles::ProfileBuilder produces. That is what lets the output be
  # projected into any landing page layout, including layouts that do not exist
  # yet, using the projection that already exists rather than a second one.
  class AiBuilder
    class GenerationError < StandardError; end
    class CreditLimitError < StandardError; end

    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    MAX_TOKENS = 4_096
    DEFAULT_MONTHLY_CREDIT = 50
    FEATURE = 'ai_landing_page_generate'

    # The sections a landing page can use. Narrower than the full profile
    # schema: a landing page has no team page, no blog and no site nav, and
    # asking for them produces content nothing will render.
    SECTIONS = %w[hero about services differentiators testimonials faq stats
                  process product specs features options floorplan].freeze

    def initialize(company:, user: nil)
      @company = company
      @user = user
    end

    # @param brief [Marketing::Brief]
    # @return [Hash] { profile:, form_fields:, layout_hint:, usage: }
    def generate(brief:)
      raise GenerationError, 'A brief is required' if brief.nil?

      check_credit!
      started = Time.current

      response = call_claude(
        system_prompt: system_prompt,
        user_message: user_message(brief),
        max_tokens: MAX_TOKENS
      )

      raw = parse_json(response[:text])
      profile, warnings = SiteProfiles::ProfileSchema.coerce(raw['profile'] || {})
      profile = merge_grounding(profile, brief)

      log_usage(brief, response, started)

      {
        profile: profile,
        form_fields: coerce_form_fields(raw['form_fields']),
        layout_hint: raw['layout_hint'].to_s.presence,
        warnings: warnings,
        usage: response
      }
    end

    private

    # Deterministic facts beat generated ones. If a scan found the dealer's real
    # phone number, the model's guess at one loses — inventing a phone number on
    # a live landing page is a serious problem, not a cosmetic one.
    def merge_grounding(profile, brief)
      grounded = brief.grounding
      return profile if grounded.blank?

      profile['contact'] = grounded['contact'].to_h.compact.reverse_merge(profile['contact'].to_h)
      profile['brand'] = profile['brand'].to_h.merge(grounded['brand'].to_h.compact) do |_k, generated, scanned|
        scanned.presence || generated
      end
      profile
    end

    def system_prompt
      <<~PROMPT
        You write landing pages for manufactured-housing and RV dealers.

        A landing page is not a website. It has one purpose, one offer and one
        action. Every section either moves the reader toward that action or is
        cut. Assume the reader arrived from an email, an ad or a text message
        and already knows roughly what this is about — so do not re-introduce
        the dealership from scratch.

        Write in the dealer's own voice where grounding content shows you what
        that sounds like. Never invent testimonials, statistics, awards,
        certifications, staff or prices. A fabricated review on a real dealer's
        page is a serious problem, and a fabricated price is a legal one. Omit a
        section entirely rather than filling it with plausible-sounding copy.

        Return ONE JSON object, no prose and no markdown fences:

        {
          "profile": {
            "brand":   { "name": str, "tagline": str },
            "contact": { "phone": str, "email": str, "address": str },
            "copy": {
              "hero":            [{ "headline": str, "subhead": str, "cta_text": str }],
              "about":           [{ "heading": str, "body": str }],
              "services":        [{ "title": str, "description": str, "icon_hint": str }],
              "differentiators": [{ "title": str, "description": str }],
              "faq":             [{ "question": str, "answer": str }],
              "stats":           [{ "number": str, "label": str, "suffix": str }],
              "process":         [{ "title": str, "description": str }],
              "product":         [{ "name": str, "model_number": str, "summary": str, "msrp": str }],
              "specs":           [{ "label": str, "value": str, "unit": str }],
              "features":        [{ "title": str, "description": str, "icon_hint": str }],
              "options":         [{ "title": str, "description": str, "price": str }],
              "floorplan":       [{ "name": str, "beds": str, "baths": str, "sqft": str }]
            },
            "seo": { "title": str, "description": str }
          },
          "form_fields": [{ "name": str, "label": str, "type": "text|email|tel|textarea|select",
                            "required": bool, "options": [str] }],
          "layout_hint": "lp-offer-focus|lp-product-spec|lp-lead-capture|lp-video-story|lp-inventory-offer"
        }

        RULES
        - The hero headline is the offer, not the dealership name.
        - Keep the form short. Every field costs conversions; ask for what a
          salesperson genuinely needs to make the first call, and nothing else.
        - Always include an email or phone field — a lead with no way to reach
          them is not a lead.
        - Pick layout_hint from what the content actually is: a spec sheet is
          lp-product-spec, a promotion is lp-offer-focus, paid traffic is
          lp-lead-capture.
        - Do NOT emit page blocks, layouts, HTML or CSS. Sections only.
      PROMPT
    end

    def user_message(brief)
      payload = { request: brief.to_h_for_prompt }
      grounded = brief.grounding
      payload[:grounding] = grounded if grounded.present?

      <<~MSG
        Write a landing page for this brief:

        #{JSON.pretty_generate(payload)}
      MSG
    end

    # A form the renderer cannot draw is worse than no form, so anything
    # malformed is dropped rather than passed through.
    def coerce_form_fields(raw)
      types = %w[text email tel textarea select]

      fields = Array(raw).filter_map do |field|
        next unless field.is_a?(Hash)

        name = field['name'].to_s.parameterize(separator: '_').presence
        next if name.blank?

        {
          'name' => name,
          'label' => field['label'].to_s.presence || name.humanize,
          'type' => types.include?(field['type'].to_s) ? field['type'].to_s : 'text',
          'required' => field['required'] ? true : false,
          'options' => Array(field['options']).map(&:to_s).presence
        }.compact
      end.uniq { |f| f['name'] }.first(8)

      ensure_contact_field(fields)
    end

    # A lead with no way to reach them is not a lead. The prompt asks for this;
    # this is what makes it true.
    def ensure_contact_field(fields)
      return fields if fields.any? { |f| %w[email tel].include?(f['type']) }

      fields + [{ 'name' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true }]
    end

    def check_credit!
      limit = (ENV['AI_LANDING_PAGE_MONTHLY_CREDIT'] || ENV['AI_CAMPAIGN_MONTHLY_CREDIT'] ||
               DEFAULT_MONTHLY_CREDIT).to_i
      return if limit <= 0

      used = AiQueryLog.where(company_id: @company.id, feature: FEATURE)
                       .where('created_at >= ?', Time.current.beginning_of_month)
                       .count
      return if used < limit

      raise CreditLimitError,
            "Monthly AI credit limit reached (#{limit}). Upgrade your plan or contact support."
    end

    def log_usage(brief, response, started)
      AiQueryLog.create!(
        company: @company,
        user: @user,
        feature: FEATURE,
        module_key: 'landing_pages',
        question: brief.prompt.to_s[0, 1000],
        generated_params: {
          site_content_profile_id: brief.site_content_profile&.id,
          duration_ms: ((Time.current - started) * 1000).round
        },
        execution_status: 'success',
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens]
      )
    rescue StandardError => e
      # Metering must never cost the generation the user already paid for.
      Rails.logger.error("[LandingPages::AiBuilder] AiQueryLog create failed: #{e.message}")
      nil
    end

    def parse_json(text)
      cleaned = text.to_s.strip.gsub(/\A```(?:json)?/, '').gsub(/```\z/, '').strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      raise GenerationError, "The model returned something that was not JSON: #{e.message}"
    end

    def call_claude(system_prompt:, user_message:, max_tokens:)
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
        model: AiModel.for(:generation),
        max_tokens: max_tokens,
        system: system_prompt,
        messages: [{ role: 'user', content: user_message }]
      }.to_json

      response = http.request(request)
      raise GenerationError, "Claude returned #{response.code}: #{response.body.to_s[0, 300]}" unless response.code.to_s == '200'

      body = JSON.parse(response.body)
      {
        text: body.dig('content', 0, 'text').to_s,
        model_version: body['model'],
        input_tokens: body.dig('usage', 'input_tokens'),
        output_tokens: body.dig('usage', 'output_tokens')
      }
    end
  end
end
