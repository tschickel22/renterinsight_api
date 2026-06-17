# frozen_string_literal: true

require 'net/http'

module DealDesk
  # Conversational solve-for-payment. The LLM does TWO things only: (1) interpret the rep's
  # prompt into a structured solve directive, and (2) write the plain-English summary +
  # per-option explanation. It NEVER produces a payment, rate, gross, or any figure.
  #
  # ALL numbers come from the deterministic engine: the same DealDesk::Solver / Engine /
  # CompareService used by the /solve and /compare endpoints. The flow is:
  #   prompt --(LLM interpret)--> intent {target_payment, levers, units?}
  #          --(ENGINE solve)---> options with computed figures
  #          --(LLM narrate)----> summary + explanations (text only, numbers untouched)
  #
  # dealer_gross is attached per option ONLY when can_view_costs (deals:read:view_cost_details);
  # for non-cost-viewers gross is stripped BEFORE the narrate step, so the LLM never sees it.
  class AiSolveService
    class Error < StandardError; end

    MODEL = 'claude-sonnet-4-6'
    LEVERS = %w[term cash_down price rate].freeze

    def initialize(company:, deal:, base_structure:, prompt:, can_view_costs: false, api_key: nil, user: nil)
      @company = company
      @deal = deal
      @base = (base_structure || {}).symbolize_keys
      @prompt = prompt.to_s
      @can_view_costs = can_view_costs
      @api_key = api_key
      @user = user
    end

    def call
      # Cap check BEFORE any LLM call (same shared monthly AI budget report_ai enforces).
      # Over cap => skip the LLM and degrade gracefully; the engine still returns every figure.
      @llm_allowed = @api_key.present? && !AiQueryLog.over_cap?(@company, user: @user)
      log_rate_limited if @api_key.present? && !@llm_allowed

      intent  = interpret                    # <-- LLM (metered) or deterministic fallback
      options = build_options(intent)        # <-- engine math only
      narrate(options)                       # <-- LLM (metered) writes summary/explanations
      { summary: @summary, options: options }
    end

    private

    # --- Step 1: interpret (LLM, with deterministic fallback) -------------------
    def interpret
      llm = interpret_via_llm
      return llm if llm

      # Fallback: pull a dollar target from the prompt; default to the common levers.
      target = @prompt[/\$?\s?([\d,]+(?:\.\d{1,2})?)\s*(?:\/\s*mo|per month|a month|month)?/, 1]
      {
        target_payment: target&.delete(',')&.to_f,
        levers: %w[term cash_down price],
        compare_units: @prompt.match?(/unit|compare|another|different|aged|lot|location/i),
        include_other_locations: @prompt.match?(/other location|another lot|cross|elsewhere/i)
      }
    end

    def interpret_via_llm
      text = claude(<<~PROMPT, action_name: 'deal_desk_ai_interpret')
        You interpret a sales rep's request into a structured directive for a DETERMINISTIC
        finance engine. Do NOT compute or output any payment, rate, gross, or dollar result.
        Only extract intent. Respond with ONLY minified JSON, no prose:
        {"target_payment": <number the customer wants per month, or null>,
         "levers": <subset of ["term","cash_down","price","rate"]>,
         "compare_units": <true if they want to consider other units>,
         "include_other_locations": <true if they want units from other locations>}

        Rep request: #{@prompt}
      PROMPT
      return nil if text.blank?

      json = JSON.parse(text.gsub(/```json|```/, '').strip)
      {
        target_payment: json['target_payment']&.to_f,
        levers: (Array(json['levers']) & LEVERS).presence || %w[term cash_down price],
        compare_units: !!json['compare_units'],
        include_other_locations: !!json['include_other_locations']
      }
    rescue StandardError => e
      Rails.logger.warn "[DealDesk AiSolve] interpret failed, using fallback: #{e.message}"
      nil
    end

    # --- Step 2: build options (ENGINE ONLY — no LLM) ---------------------------
    def build_options(intent)
      target = intent[:target_payment]
      options = []

      if target.nil?
        # No target stated — return the current structure as a baseline option.
        options << engine_option(:baseline, @base)
      else
        solver = Solver.new(@base)
        intent[:levers].each do |lever|
          options.concat(lever_options(solver, lever, target))
        end
      end

      if intent[:compare_units] || intent[:include_other_locations]
        options.concat(unit_options(intent, target))
      end

      options
    end

    def lever_options(solver, lever, target)
      case lever
      when 'term', 'cash_down', 'price'
        solved = solver.solve_for_payment(lever: lever, target_payment: target)
        merged = @base.merge(lever_key(lever) => solved[lever_field(lever)])
        [engine_option(lever, merged)]
      when 'rate'
        rate_candidate_options(target)
      else
        []
      end
    rescue ArgumentError
      []
    end

    def lever_key(lever)
      { 'term' => :term_months, 'cash_down' => :cash_down, 'price' => :price }[lever]
    end

    def lever_field(lever)
      { 'term' => :term_months, 'cash_down' => :cash_down, 'price' => :price }[lever]
    end

    # Distinct rates from the company's active lender tiers → one option each (capped).
    def rate_candidate_options(_target)
      rates = @company.lender_programs.active.includes(:tiers)
                      .flat_map { |p| p.tiers.map(&:rate) }.compact.map(&:to_f).uniq.sort.first(4)
      rates.map { |rate| engine_option('rate', @base.merge(apr: rate), rate: rate) }
    end

    # Engine.compute → contract-shaped option. dealer_gross gated.
    def engine_option(lever, merged, extra = {})
      res = Engine.compute(merged)
      opt = {
        lever: lever.to_s,
        rate: extra[:rate],
        term_months: res.term_months,
        cash_down: merged[:cash_down]&.to_f,
        amount_financed: res.amount_financed,
        monthly_payment: res.monthly_payment,
        out_the_door: res.out_the_door
      }
      opt[:dealer_gross] = res.gross&.total if @can_view_costs && res.gross
      opt.compact
    end

    # Candidate-unit options via the SAME CompareService used by /compare.
    def unit_options(intent, target)
      return [] unless @deal.vehicle

      result = CompareService.new(
        company: @company, deal: @deal, base_structure: @base, target_payment: target,
        include_other_locations: intent[:include_other_locations]
      ).call

      Array(result[:candidates]).first(3).map do |c|
        opt = {
          lever: 'unit', vehicle_id: c[:vehicle_id], location_id: c[:location_id],
          days_on_lot: c[:days_on_lot], amount_financed: c[:amount_financed],
          monthly_payment: c[:monthly_payment], out_the_door: c[:out_the_door]
        }
        opt[:dealer_gross] = c[:dealer_gross] if @can_view_costs
        opt.compact
      end
    rescue StandardError => e
      Rails.logger.warn "[DealDesk AiSolve] unit options failed: #{e.message}"
      []
    end

    # --- Step 3: narrate (LLM writes prose over ENGINE numbers) -----------------
    def narrate(options)
      text = claude(<<~PROMPT, action_name: 'deal_desk_ai_narrate')
        A deterministic finance engine produced these deal-structure options (all numbers are
        FINAL — never change, recompute, or invent any figure). Write a short plain-English
        summary for the sales rep and a one-sentence explanation per option, referencing only
        the provided numbers. Respond with ONLY minified JSON:
        {"summary": "<text>", "explanations": ["<option 0>", "<option 1>", ...]}

        Rep request: #{@prompt}
        Options (index-aligned JSON): #{options.to_json}
      PROMPT
      return if text.blank?

      json = JSON.parse(text.gsub(/```json|```/, '').strip)
      @summary = json['summary']
      Array(json['explanations']).each_with_index do |ex, i|
        options[i][:explanation] = ex if options[i]
      end
    rescue StandardError => e
      Rails.logger.warn "[DealDesk AiSolve] narrate failed (numbers still returned): #{e.message}"
      nil
    end

    # --- Anthropic call: gated by the cap, METERED per call --------------------
    # Returns the response text, or nil when the LLM is skipped (no key / over cap) or
    # errors. Every successful call records an AiQueryLog row (feature deal_desk_ai) so
    # both the interpret and narrate calls are billed to the company's shared AI budget.
    def claude(prompt, action_name:)
      return nil unless @llm_allowed

      body = post_to_anthropic(prompt)
      return nil if body.nil?

      usage = body['usage'] || {}
      record_usage(action_name: action_name,
                   input: usage['input_tokens'].to_i, output: usage['output_tokens'].to_i)
      body.dig('content', 0, 'text')
    end

    # Raw HTTP (same pattern as report_ai / ai_action_service). Returns the parsed body.
    def post_to_anthropic(prompt)
      uri = URI('https://api.anthropic.com/v1/messages')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['x-api-key'] = @api_key
      req['anthropic-version'] = '2023-06-01'
      resp = http.request(req, { model: MODEL, max_tokens: 1200,
                                 messages: [{ role: 'user', content: prompt }] }.to_json)
      return nil unless resp.code == '200'

      JSON.parse(resp.body)
    rescue StandardError => e
      Rails.logger.warn "[DealDesk AiSolve] Claude call failed: #{e.message}"
      nil
    end

    def record_usage(action_name:, input:, output:)
      AiQueryLog.create!(
        company_id: @company.id, user_id: @user&.id, location_id: Current.location_id,
        feature: 'deal_desk_ai', action_name: action_name, question: @prompt[0, 1000],
        execution_status: 'success', input_tokens: input, output_tokens: output,
        cost_cents: cost_cents(input, output)
      )
    rescue StandardError => e
      Rails.logger.warn "[DealDesk AiSolve] usage record failed: #{e.message}"
    end

    def log_rate_limited
      AiQueryLog.create!(
        company_id: @company.id, user_id: @user&.id, location_id: Current.location_id,
        feature: 'deal_desk_ai', action_name: 'deal_desk_ai_rate_limited',
        question: @prompt[0, 1000], execution_status: 'rate_limited'
      )
    rescue StandardError => e
      Rails.logger.warn "[DealDesk AiSolve] rate_limited log failed: #{e.message}"
    end

    # Sonnet pricing, matching ai_action_service#calculate_cost_cents.
    def cost_cents(input, output)
      (((input * 0.000003) + (output * 0.000015)) * 100).ceil
    end
  end
end
