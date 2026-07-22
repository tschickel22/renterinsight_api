module Audiences
  class AiBuilder
    class GenerationError < StandardError; end
    class CreditLimitError < StandardError; end

    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    GENERATE_MODEL = AiModel.for(:generation)
    REFINE_MODEL = AiModel.for(:refine)
    GENERATE_MAX_TOKENS = 2048
    REFINE_MAX_TOKENS = 1024

    DEFAULT_MONTHLY_CREDIT = 50

    def initialize(company:, user:)
      @company = company
      @user = user
    end

    def generate(prompt:, source_type: 'Lead')
      check_credit!
      raise GenerationError, "Unsupported source_type: #{source_type}" unless Audience::SOURCE_TYPES.include?(source_type)

      context = build_context(source_type)
      system_prompt = system_prompt_for(:generate, source_type)
      user_message = "#{prompt}\n\nContext:\n#{context.to_json}"

      response = call_claude(
        system_prompt: system_prompt, user_message: user_message,
        model: GENERATE_MODEL, max_tokens: GENERATE_MAX_TOKENS
      )

      filter_tree = parse_filter_tree(response[:text])
      log = log_usage(prompt, response, source_type, 'ai_audience_generate', parent_id: nil)

      AudienceAiGeneration.create!(
        company: @company, user: @user,
        prompt: prompt,
        context_snapshot: context,
        generated_filter_tree: filter_tree,
        status: 'generated',
        source_type: source_type,
        model_version: GENERATE_MODEL,
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        ai_query_log_id: log&.id
      )
    end

    def refine(generation:, feedback:)
      check_credit!

      source_type = generation.source_type
      system_prompt = system_prompt_for(:refine, source_type)
      user_message = <<~MSG
        Existing filter tree: #{generation.generated_filter_tree.to_json}

        Feedback: #{feedback}

        Return the COMPLETE updated filter tree in the same JSON shape.
      MSG

      response = call_claude(
        system_prompt: system_prompt, user_message: user_message,
        model: REFINE_MODEL, max_tokens: REFINE_MAX_TOKENS
      )

      filter_tree = parse_filter_tree(response[:text])
      log = log_usage(feedback, response, source_type, 'ai_audience_refine', parent_id: generation.id)

      AudienceAiGeneration.create!(
        company: @company, user: @user,
        prompt: feedback,
        context_snapshot: generation.context_snapshot,
        generated_filter_tree: filter_tree,
        status: 'refined',
        source_type: source_type,
        parent_generation_id: generation.id,
        model_version: REFINE_MODEL,
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        ai_query_log_id: log&.id
      )
    end

    def accept(generation:, name:, description: nil)
      audience = nil
      ActiveRecord::Base.transaction do
        audience = @company.audiences.create!(
          name: name,
          description: description,
          source_type: generation.source_type,
          filter_tree: generation.generated_filter_tree,
          created_by_user_id: @user.id,
          generated_from_ai_generation_id: generation.id
        )

        compiler = Audiences::FilterCompiler.new(
          company: @company,
          source_type: audience.source_type,
          filter_tree: audience.filter_tree
        )
        audience.update!(estimated_count: compiler.count, estimated_at: Time.current)

        generation.update!(status: 'accepted', audience_id: audience.id)
      end
      audience
    end

    private

    def check_credit!
      limit = (ENV['AI_AUDIENCE_MONTHLY_CREDIT'] || ENV['AI_CAMPAIGN_MONTHLY_CREDIT'] || DEFAULT_MONTHLY_CREDIT).to_i
      return if limit <= 0
      used = AiQueryLog.where(company_id: @company.id, feature: %w[ai_audience_generate ai_audience_refine])
                       .where('created_at >= ?', Time.current.beginning_of_month).count
      if used >= limit
        raise CreditLimitError, "Monthly AI audience credit limit reached (#{limit}). Upgrade your plan or contact support."
      end
    end

    def build_context(source_type)
      schema = Audiences::FieldSchema.for_source_type(source_type)
      {
        'company' => { 'name' => @company.name },
        'source_type' => source_type,
        'available_fields' => schema.map { |f| f.slice(:key, :label, :type, :operators, :options).stringify_keys },
        'available_tag_count' => safe_tag_count
      }
    end

    def safe_tag_count
      return 0 unless @company.respond_to?(:tags)
      @company.tags.count
    rescue StandardError
      0
    end

    def system_prompt_for(mode, source_type)
      base = <<~SYS
        You are an expert audience-builder for RenterInsight (a CRM/DMS for manufactured-home and RV dealerships).

        Your job: convert a user's natural-language description of a recipient list into a structured filter tree.

        OUTPUT RULES:
        - You MUST respond with a single JSON object representing the filter tree, nothing else. No prose, no markdown, no explanation.
        - The shape is recursive:
          {
            "type": "and" | "or",
            "children": [
              { "field": "...", "operator": "...", "value": ... },
              { "type": "or", "children": [...] }
            ]
          }
        - Leaf nodes have field, operator, value.
        - Group nodes have type ("and" or "or") and children array.

        SOURCE TYPE: #{source_type}

        AVAILABLE FIELDS, OPERATORS, AND TYPES are provided in the context. ONLY use fields and operators that appear there.

        TIME-BASED QUERIES:
        - "in the last X days" => use the timestamp field with operator "greater_than" and an ISO timestamp value.
        - "no activity in last X days" or "stale": use "days_since_greater_than" on last_activity_at (if available) or created_at, value = X.

        TAG QUERIES:
        - "with tag hot" => { field: "tags", operator: "tags_include", value: "hot" }
        - "tagged hot or warm" => { field: "tags", operator: "tags_any_of", value: ["hot", "warm"] }
        - "without tag cold" => { field: "tags", operator: "tags_exclude", value: "cold" }

        BOOLEAN LOGIC:
        - "and" / "with" / "who" => combine with type: "and"
        - "or" => use type: "or" group
        - "but not" / "except" => for v1, encode as type: "and" with a tags_exclude or not_equals leaf

        EMPTY FILTER:
        - If the user says "everyone" or "all leads", return { "type": "and", "children": [] }
      SYS

      mode == :refine ? base + "\n\nThe user is iterating on a previous filter tree. Apply their feedback and return the COMPLETE updated tree." : base
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

    def parse_filter_tree(text)
      cleaned = text.to_s.strip
      cleaned = cleaned.gsub(/\A```(?:json)?\s*/, '').gsub(/\s*```\z/, '')
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      raise GenerationError, "AI returned invalid JSON: #{e.message[0, 200]}"
    end

    def log_usage(prompt_text, response, source_type, feature, parent_id:)
      cost_cents = compute_cost(response[:input_tokens].to_i, response[:output_tokens].to_i, feature)
      AiQueryLog.create!(
        company: @company, user: @user,
        feature: feature,
        module_key: 'campaigns',
        question: prompt_text.to_s[0, 1000],
        generated_params: { source_type: source_type, parent_id: parent_id },
        execution_status: 'success',
        input_tokens: response[:input_tokens],
        output_tokens: response[:output_tokens],
        cost_cents: cost_cents
      )
    rescue => e
      Rails.logger.error "[Audiences::AiBuilder] AiQueryLog create failed: #{e.message}"
      nil
    end

    def compute_cost(input_tokens, output_tokens, feature)
      cents = if feature == 'ai_audience_generate'
                (input_tokens * 3.0 + output_tokens * 15.0) / 10_000.0
              else
                (input_tokens * 0.25 + output_tokens * 1.25) / 10_000.0
              end
      cents.round
    end
  end
end
