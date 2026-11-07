# frozen_string_literal: true

require 'net/http'

module Assistant
  # Writes the assistant's next text and reads the conversation for what the
  # buyer wants (backlog E96). One Claude call, forced through a tool so the
  # answer comes back as fields rather than prose we have to parse.
  #
  # Grounded the same way as the website concierge: the dealer's own facts and
  # stock are the only things it may answer from, and anything else is handed
  # to a person. The hard rules are repeated in code (Assistant::Rules), so the
  # prompt is a first line, not the only one.
  class Brain
    API_URL = 'https://api.anthropic.com/v1/messages'
    MAX_TOKENS = 700
    HISTORY = 14
    STOCK_LIMIT = 15

    QUALIFICATION_FIELDS = %w[
      budget monthly_target timeline credit_self_rating land_status home_type
      bedrooms delivery_area trade_in best_time
    ].freeze

    HANDOFF_REASONS = %w[
      asked_for_person upset finance_or_credit legal_or_warranty trade_in_value
      appointment unsure other
    ].freeze

    # Who the buyer is, as they tell it. Copied onto the lead's own fields
    # (AssistantReplyJob), the same fields the lead form fills.
    CONTACT_FIELDS = %w[first_name last_name email street city state zip].freeze

    Result = Struct.new(:reply, :qualification, :contact, :resend_invite, :handoff, :handoff_reason, :summary, :usage,
                        keyword_init: true)

    def initialize(conversation:, settings:, history:, feedback: nil)
      @conversation = conversation
      @company = conversation.company
      @lead = conversation.conversable
      @settings = settings
      @history = Array(history).last(HISTORY)
      @feedback = feedback
    end

    def call
      body = request_body
      response = post(body)
      input = Array(response['content']).detect { |c| c['type'] == 'tool_use' }&.dig('input') || {}
      Result.new(
        reply: input['reply'].to_s.strip,
        qualification: input['qualification'].to_h.slice(*QUALIFICATION_FIELDS).compact_blank,
        contact: input['contact'].to_h.slice(*CONTACT_FIELDS).transform_values { |v| v.to_s.strip }.compact_blank,
        resend_invite: input['resend_invite'] == true,
        handoff: input['handoff'] == true,
        handoff_reason: HANDOFF_REASONS.include?(input['handoff_reason']) ? input['handoff_reason'] : (input['handoff'] ? 'other' : nil),
        summary: input['summary'].to_s.strip.truncate(500),
        usage: { model: response['model'], input_tokens: response.dig('usage', 'input_tokens'),
                 output_tokens: response.dig('usage', 'output_tokens') }
      )
    end

    def system_prompt
      facts = knowledge.to_h
      name = @settings.assistant_name
      <<~PROMPT
        You text with people who asked #{facts[:dealer_name]}, a manufactured home dealer, about a home.
        Your name is #{name}. You work with the team at #{facts[:dealer_name]}. If asked, you are the dealership's
        assistant and a person on the team can take over at any time.
        Tone: #{@settings['tone'] == 'professional' ? 'polite and professional' : 'warm, friendly and relaxed'}.

        Your job: answer their questions, learn what they need, and get them to visit or talk with the team.
        Learn, one question at a time and only when it fits: whether they own land or need land or a community,
        the size of home and bedrooms, their timeline, their budget, how they would pay (cash, financing, or not sure),
        and a good time to visit. If they want to visit or want details sent and you do not have their full name or
        email address, ask for it.

        RULES. Breaking one of these costs the dealer a sale or worse.
        1. Text message style: one or two short sentences, under 300 characters. No lists, no emojis, no signatures.
        2. Answer ONLY from the facts and homes below. Never invent a home, price, feature, delivery date or policy.
           If you do not know, say you will check with the team, and hand off.
        3. Never state a monthly payment, interest rate, down payment, or whether someone will be approved.
           For payment or credit questions say the finance manager will go over it with them, and hand off.
        4. Never send a link or a web address of any kind.
        5. Do not use dashes as punctuation.
        6. If they ask to talk with a person, are upset, ask about legal, warranty or a complaint, want a trade in
           valued, or want to book a new visit or change or cancel one, hand off with a short friendly reply saying
           someone will text them.
        8. If they ask about a visit already booked (when, where, with whom), answer from THEIR APPOINTMENTS below.
           If they ask for the invite or the details again, set resend_invite and tell them the calendar invite is on
           its way to their email (only when an email is on file; otherwise just text them the details).
        7. Do not repeat a question they already answered. Do not greet them again after the first message.

        Always call the respond tool.

        FACTS
        Dealer: #{facts[:dealer_name]}
        Phone: #{facts[:phone] || 'not provided'}
        Address: #{facts[:address] || 'not provided'}
        Hours: #{facts[:hours].presence || 'not provided'}
        Brands carried: #{facts[:manufacturers].presence&.join(', ') || 'not provided'}
        Homes in stock: #{facts[:inventory_count]}#{facts[:price_range] ? ", priced $#{facts[:price_range][:min]} to $#{facts[:price_range][:max]}" : ''}
        #{@settings['extra_facts'].present? ? "More from the dealer: #{@settings['extra_facts'].to_s.squish}" : ''}

        HOMES (the only homes you may mention)
        #{stock_lines.presence || 'No homes listed.'}

        THIS BUYER
        Name on file: #{[@lead.try(:first_name), @lead.try(:last_name)].compact_blank.join(' ').presence || 'unknown'}
        Email on file: #{@lead.try(:email).presence || 'none'}
        Came from: #{source_name || 'unknown'}
        What they first asked: #{first_request || 'nothing recorded'}
        Known so far: #{@conversation.qualification.presence&.to_json || 'nothing yet'}

        THEIR APPOINTMENTS
        #{appointment_lines.presence || 'None booked.'}
        #{@feedback ? "\nYour last draft could not be sent (#{@feedback}). Write a new one that follows the rules." : ''}
      PROMPT
    end

    private

    def request_body
      {
        model: AiModel.for(:lead_assistant),
        max_tokens: MAX_TOKENS,
        thinking: { type: 'disabled' },
        system: system_prompt,
        tools: [tool],
        tool_choice: { type: 'tool', name: 'respond' },
        messages: messages
      }
    end

    def tool
      {
        name: 'respond',
        description: 'Send the next text to the buyer and record what you learned.',
        input_schema: {
          type: 'object',
          properties: {
            reply: { type: 'string', description: 'The text to send. Empty only when handing off says it all.' },
            qualification: {
              type: 'object',
              description: 'Only what the buyer actually said. Omit anything unknown.',
              properties: QUALIFICATION_FIELDS.index_with { { type: 'string' } }
            },
            contact: {
              type: 'object',
              description: 'Name, email or address the buyer gave in this conversation. Omit anything they did not say.',
              properties: CONTACT_FIELDS.index_with { { type: 'string' } }
            },
            resend_invite: { type: 'boolean', description: 'True to email the calendar invite for their next appointment again.' },
            handoff: { type: 'boolean', description: 'True when a person should take over now.' },
            handoff_reason: { type: 'string', enum: HANDOFF_REASONS },
            summary: { type: 'string', description: 'One or two sentences for the sales rep: who this is and what they want. Use their name or "they", never he or she.' }
          },
          required: %w[reply handoff summary]
        }
      }
    end

    # Claude needs alternating turns starting with the buyer. Our first text
    # comes before any buyer message, so it is folded into a lead-in.
    def messages
      turns = []
      @history.each do |comm|
        role = comm.direction == 'inbound' ? 'user' : 'assistant'
        text = comm.body.to_s.strip.truncate(600)
        next if text.blank?

        if turns.last && turns.last[:role] == role
          turns.last[:content] += "\n#{text}"
        else
          turns << { role: role, content: text }
        end
      end
      if turns.first && turns.first[:role] == 'assistant'
        opener = turns.shift[:content]
        if turns.first
          turns.first[:content] = "(We texted first: \"#{opener}\")\n#{turns.first[:content]}"
        else
          turns << { role: 'user', content: "(We texted first: \"#{opener}\". The buyer has not replied.)" }
        end
      end
      turns = [{ role: 'user', content: '(The buyer has not replied yet.)' }] if turns.empty?
      turns << { role: 'user', content: '(Continue.)' } if turns.last[:role] == 'assistant'
      turns
    end

    # Company records only, not a website: a company can hold several sites,
    # including demos built from templates that carry a sample business name
    # and footer ("Coastal Breeze Homes" answered for Summit Park on staging).
    # Texts go out under the company's name, so the facts must match it.
    def knowledge
      @knowledge ||= Concierge::Knowledge.new(website: nil, company: @company)
    end

    def stock_lines
      @company.vehicles.where(is_deleted: [false, nil], status: Concierge::InventorySearch::SERVABLE)
              .order(updated_at: :desc).limit(STOCK_LIMIT).map do |v|
        bits = [[v.year, v.make, v.model].compact_blank.join(' ')]
        bits << "#{v.bedrooms} bed" if v.bedrooms.present?
        bits << "#{v.bathrooms.to_s.sub(/\.0\z/, '')} bath" if v.bathrooms.present?
        bits << "#{v.square_feet} sq ft" if v.square_feet.present?
        bits << "$#{v.sale_price.to_i}" if v.sale_price.to_i.positive?
        "- #{bits.join(', ')}"
      end.join("\n")
    rescue StandardError
      ''
    end

    # Upcoming visits for this buyer, so "what time is my appointment?" is
    # answered rather than handed off.
    def upcoming_appointments
      Assistant::Appointments.upcoming_for(@lead)
    end

    def appointment_lines
      upcoming_appointments.map do |a|
        rep = (a.assigned_to || a.user)&.try(:first_name).presence
        place = a.try(:meeting_location).presence || a.try(:location).presence || knowledge.contact[:address]
        "- #{::Appointments::TimeText.for(a, @company)}#{" at #{place}" if place}#{" with #{rep}" if rep}"
      end.join("\n")
    rescue StandardError
      ''
    end

    def source_name
      @lead.try(:source).try(:name)
    end

    def first_request
      sub = @lead.respond_to?(:intake_submissions) ? @lead.intake_submissions.order(:created_at).last : nil
      text = sub&.data.to_h.values.select { |v| v.is_a?(String) && v.length > 15 && !v.include?('@') }.join(' ')
      (text.presence || @lead.try(:notes)).to_s.squish.truncate(400).presence
    rescue StandardError
      nil
    end

    def post(body)
      api_key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
      raise 'Anthropic API key not configured' if api_key.blank?

      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30
      http.open_timeout = 10
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['x-api-key'] = api_key
      req['anthropic-version'] = '2023-06-01'
      req.body = body.to_json
      res = http.request(req)
      raise "Claude returned #{res.code}: #{res.body.to_s.truncate(200)}" unless res.code.to_s == '200'

      JSON.parse(res.body)
    end
  end
end
