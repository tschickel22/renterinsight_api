# frozen_string_literal: true

require 'net/http'

module Concierge
  # Answers a visitor, spending a model call only when the cheaper tiers cannot.
  #
  # Three tiers, in order:
  #
  #   1. Inventory query. "3 bed under 80k" becomes a database filter. No model,
  #      and no chance of inventing a home, which is the failure that would cost
  #      a dealer most.
  #   2. Deterministic answer. Hours, address, phone, financing, delivery,
  #      booking. Facts we hold, read straight off the record.
  #   3. The model, grounded in this dealer's own facts and told to hand off
  #      rather than guess.
  #
  # On a typical dealer site the first two carry most of the traffic, so the bill
  # tracks genuinely open questions rather than volume. Every escalation is
  # logged with its token counts, so the ratio is measurable instead of assumed.
  class Responder
    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    # Short answers on purpose. A chat bubble is not a brochure, and a long reply
    # is both more expensive and less likely to be read.
    MAX_TOKENS = 400
    HISTORY_TURNS = 6

    Result = Struct.new(:text, :actions, :listings, :source, :usage, keyword_init: true)

    # visitor: whatever the assistant has already got out of them. Used only to
    # carry their name and email into the dealer's scheduler, so being asked for
    # them before the calendar costs the visitor nothing.
    def initialize(website:, message:, history: [], user: nil, company: nil, visitor: {},
                   capture_enabled: false)
      @website = website
      @company = company || website&.company
      @message = message.to_s.strip
      @history = Array(history).last(HISTORY_TURNS)
      @user = user
      @visitor = (visitor || {}).symbolize_keys
      @capture_enabled = capture_enabled
    end

    def call
      return blank_result if @message.blank?

      filters = InventoryQuery.new(@message).call
      return inventory_result(filters) unless filters.nil?

      answered = DeterministicAnswer.new(
        text: @message, knowledge: knowledge,
        booking_url: booking_url, lead_form_path: lead_form_path,
        capture_enabled: @capture_enabled
      ).call
      return Result.new(text: answered[:text], actions: answered[:actions], listings: [], source: 'rules') if answered

      model_result
    end

    private

    def knowledge
      @knowledge ||= Knowledge.new(website: @website, company: @company)
    end

    def booking_url
      @booking_url ||= begin
        resolved = Websites::BookingUrl.resolve(
          company: @company, location: @website&.location, user: @user
        )
        Websites::BookingPrefill.apply(
          resolved, name: @visitor[:name], email: @visitor[:email], phone: @visitor[:phone]
        )
      end
    end

    def lead_form_path
      '/contact'
    end

    def blank_result
      Result.new(text: 'What can I help you with?', actions: [], listings: [], source: 'rules')
    end

    # Matching homes, straight from the same scope the public grid uses, so the
    # concierge can never show a home the site would refuse to.
    def inventory_result(filters)
      matches = Concierge::InventorySearch.new(company: @company, filters: filters).call

      if matches.empty?
        return Result.new(
          text: "I couldn't find anything matching that right now. Tell me roughly what you're " \
                'after and I can have someone check what is coming in.',
          actions: [{ type: 'form', label: 'Tell us what you need', path: lead_form_path }],
          listings: [], source: 'inventory'
        )
      end

      Result.new(
        text: "Here #{matches.size == 1 ? 'is one that fits' : "are #{matches.size} that fit"}.",
        actions: [{ type: 'link', label: 'See all inventory', url: '/inventory' }],
        listings: matches, source: 'inventory'
      )
    end

    def model_result
      response = call_claude
      Result.new(
        text: response[:text].presence || fallback_text,
        actions: [{ type: 'form', label: 'Talk to the team', path: lead_form_path }],
        listings: [], source: 'model', usage: response.slice(:model_version, :input_tokens, :output_tokens)
      )
    rescue StandardError => e
      Rails.logger.warn("[Concierge] model call failed: #{e.class}: #{e.message}")
      # A visitor must never see a stack trace or a silence. Handing off is a
      # perfectly good answer and is what a busy salesperson would do.
      Result.new(text: fallback_text,
                 actions: [{ type: 'form', label: 'Talk to the team', path: lead_form_path }],
                 listings: [], source: 'fallback')
    end

    def fallback_text
      "That one is better answered by the team. Leave your details and someone from " \
        "#{knowledge.dealer_name} will get straight back to you."
    end

    def system_prompt
      facts = knowledge.to_h
      <<~PROMPT
        You are the assistant on the website of #{facts[:dealer_name]}, a manufactured home dealer.

        Answer ONLY from the facts below. If the answer is not in them, say you will pass it to
        the team and stop. Never invent a home, a price, a finance term, a delivery date or a
        policy. Never quote an interest rate or say whether someone will be approved.

        Keep it to two or three sentences. Write plainly, the way a salesperson would speak.
        Do not use dashes as punctuation.

        FACTS
        Dealer: #{facts[:dealer_name]}
        Phone: #{facts[:phone] || 'not provided'}
        Address: #{facts[:address] || 'not provided'}
        Hours: #{facts[:hours] || 'not provided'}
        Homes available: #{facts[:inventory_count]}
        Price range: #{facts[:price_range] ? "$#{facts[:price_range][:min]} to $#{facts[:price_range][:max]}" : 'not provided'}
        Brands carried: #{facts[:manufacturers].presence&.join(', ') || 'not provided'}

        PAGES ON THIS SITE
        #{facts[:pages].map { |p| "#{p[:title]} (#{p[:path]}): #{p[:summary]}" }.join("\n")}
      PROMPT
    end

    def call_claude
      api_key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
      raise 'Anthropic API key not configured' if api_key.blank?

      uri = URI(CLAUDE_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 20
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = {
        # Role-keyed, so the whole concierge moves models with one ENV change.
        model: AiModel.for(:concierge),
        max_tokens: MAX_TOKENS,
        # Explicit rather than omitted: on newer models adaptive thinking is on
        # by default and spends max_tokens, which would truncate a 400 token
        # answer to nothing.
        thinking: { type: 'disabled' },
        system: system_prompt,
        messages: conversation
      }.to_json

      response = http.request(request)
      raise "Claude returned #{response.code}" unless response.code.to_s == '200'

      body = JSON.parse(response.body)
      {
        text: body.dig('content', 0, 'text').to_s.strip,
        model_version: body['model'],
        input_tokens: body.dig('usage', 'input_tokens'),
        output_tokens: body.dig('usage', 'output_tokens')
      }
    end

    # Prior turns, so a follow-up like "how much is that one" has something to
    # refer to. Capped, because a chat that has run long is a chat that should
    # have become a lead.
    def conversation
      turns = @history.filter_map do |turn|
        role = turn['role'] || turn[:role]
        content = (turn['content'] || turn[:content]).to_s.strip
        next if content.blank? || !%w[user assistant].include?(role.to_s)

        { role: role.to_s, content: content.truncate(500) }
      end

      turns + [{ role: 'user', content: @message.truncate(500) }]
    end
  end
end
