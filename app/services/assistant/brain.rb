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
      appointment visit_time ready_for_rep unsure other
    ].freeze

    # Who the buyer is, as they tell it. Copied onto the lead's own fields
    # (AssistantReplyJob), the same fields the lead form fills.
    CONTACT_FIELDS = %w[first_name last_name email phone street city state zip].freeze

    Result = Struct.new(:reply, :qualification, :contact, :resend_invite, :photo_home_id, :question, :question_answered,
                        :question_topic, :handoff, :handoff_reason, :summary, :usage, :subject, :book_slot, :cancel_visit,
                        keyword_init: true)

    # opener: write the first text to a new lead (Quinn starts it, E96).
    # showing: names of homes the website chat shows as cards under this reply.
    # follow_up: { number:, of:, channel: :text|:email } to write a follow-up
    # to a buyer who went quiet (Assistant::FollowUp).
    # reply_channel: :email when answering the buyer's email. purpose: what the
    # call is for, for the usage log (text_reply, email_reply, opener,
    # follow_up, chat).
    def initialize(conversation:, settings:, history:, feedback: nil, opener: false, showing: [], follow_up: nil,
                   reply_channel: nil, purpose: nil, booking: nil, missed_visit: nil)
      @showing = Array(showing)
      # Assistant::Booking: open times to offer, and the ids Quinn books by.
      @booking = booking
      # The time of a visit they missed, to offer a new one (no-show).
      @missed_visit = missed_visit
      @follow_up = follow_up
      @reply_channel = reply_channel
      @purpose = purpose
      @conversation = conversation
      @opener = opener
      @web = conversation.web_chat?
      @company = conversation.company
      @lead = conversation.conversable
      @settings = settings
      @history = Array(history).last(HISTORY)
      @feedback = feedback
    end

    def call
      body = request_body
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = post(body)
      log_usage(response, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      input = Array(response['content']).detect { |c| c['type'] == 'tool_use' }&.dig('input') || {}
      Result.new(
        reply: input['reply'].to_s.strip,
        qualification: input['qualification'].to_h.slice(*QUALIFICATION_FIELDS).compact_blank,
        contact: input['contact'].to_h.slice(*CONTACT_FIELDS).transform_values { |v| v.to_s.strip }.compact_blank,
        resend_invite: input['resend_invite'] == true,
        photo_home_id: stock_ids.include?(input['photo_home_id'].to_i) ? input['photo_home_id'].to_i : nil,
        question: input['buyer_question'].to_s.squish.truncate(300).presence,
        question_answered: input['question_answered'] == true,
        question_topic: AssistantQuestion::TOPICS.include?(input['question_topic']) ? input['question_topic'] : nil,
        handoff: input['handoff'] == true,
        handoff_reason: HANDOFF_REASONS.include?(input['handoff_reason']) ? input['handoff_reason'] : (input['handoff'] ? 'other' : nil),
        summary: input['summary'].to_s.strip.truncate(500),
        subject: input['subject'].to_s.strip.presence,
        book_slot: booking? ? input['book_slot'].to_s.strip.upcase.presence : nil,
        cancel_visit: booking? && input['cancel_visit'] == true,
        usage: { model: response['model'], input_tokens: response.dig('usage', 'input_tokens'),
                 output_tokens: response.dig('usage', 'output_tokens') }
      )
    end

    def system_prompt
      facts = knowledge.to_h
      name = @settings.assistant_name
      <<~PROMPT
        #{@web ? "You chat with visitors on the website of #{facts[:dealer_name]}, a manufactured home dealer." : "You text with people who asked #{facts[:dealer_name]}, a manufactured home dealer, about a home."}
        Your name is #{name}. You work with the team at #{facts[:dealer_name]}. If asked, you are the dealership's
        assistant and a person on the team can take over at any time.
        Tone: #{@settings['tone'] == 'professional' ? 'polite and professional' : 'warm, friendly and relaxed'}.

        #{goal_text}
        #{opener_text}
        #{follow_up_text}
        #{missed_visit_text}
        RULES. Breaking one of these costs the dealer a sale or worse.
        1. #{style_rule}
        2. Answer ONLY from the facts and homes below. Never invent a home, price, feature, delivery date or policy.
           #{unknown_rule}
        3. Never state a monthly payment, interest rate, down payment, or whether someone will be approved.
           For payment or credit questions say the finance manager will go over it with them, and hand off.
        4. #{links_rule}
        5. Do not use dashes as punctuation.
        6. If they ask to talk with a person, are upset, ask about legal, warranty or a complaint, or want a trade in
           valued, hand off with a short friendly reply saying someone from the team will #{follow_up_word}.
           #{visit_rule}
           #{dealer_handoff_rules}
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

        DEALER ANSWERS TO COMMON QUESTIONS
        #{faq_lines.presence || 'None yet.'}

        FROM THE DEALER'S WEBSITES (use when it fits; the facts and dealer answers above win when they differ)
        #{website_lines.presence || 'Nothing.'}

        HOMES (the only homes you may mention)
        #{stock_lines.presence || 'No homes listed.'}

        THIS BUYER
        Name on file: #{name_on_file}
        Email on file: #{@lead.try(:email).presence || 'none'}
        #{@web ? "Mobile on file: #{@lead.try(:phone).present? ? 'yes' : 'none'}" : ''}
        Came from: #{source_name || 'unknown'}
        What they first asked: #{first_request || 'nothing recorded'}
        Known so far: #{@conversation.qualification.presence&.to_json || 'nothing yet'}

        THEIR APPOINTMENTS
        #{appointment_lines.presence || 'None booked.'}
        #{booking? ? "\nOPEN TIMES (the only times you may offer or book, with #{@booking.rep&.first_name.presence || 'the team'})\n#{@booking.prompt_lines}" : ''}
        #{@showing.any? ? "\nThe chat shows these homes as cards under your reply, matching their search: #{@showing.join('; ')}. You may refer to them as the homes below; do not list them again and do not call them cards." : ''}
        #{@feedback ? "\nYour last draft could not be sent (#{@feedback}). Write a new one that follows the rules." : ''}
      PROMPT
    end

    private

    # "Text from (352) ..." is what we called them before anyone knew.
    def name_on_file
      name = [@lead.try(:first_name), @lead.try(:last_name)].compact_blank.join(' ')
      name.blank? || name.match?(Assistant::Learn::PLACEHOLDER_NAME) ? 'unknown (ask for it when it fits)' : name
    end

    # What Quinn works toward, from the dealer's goal setting.
    def goal_text
      learn = 'Learn, one question at a time and only when it fits: whether they own land or need land or a community, ' \
              'the size of home and bedrooms, their timeline, their budget, how they would pay (cash, financing, or not sure), ' \
              'and a good time to visit.'
      contact = @web ? 'If they want to visit, be contacted or have details sent, ask for their name and an email address or mobile number ' \
                       '(the chat itself asks whether texting is OK, so do not ask that).' :
                       'If they want to visit or want details sent and you do not have their full name or email address, ask for it.'
      case booking_mode
      when :book
        "Your goal is a visit to see homes in person. Answer their questions, learn what they need, and invite them to come see " \
          "homes that fit. #{learn} #{contact} " +
          (booking? ? 'When they are open to a visit, offer two open times and book the one they pick (see VISITS).' :
            'Once they give a day and time to visit and you have their name and a way to reach them, hand off with reason ' \
            'visit_time, saying the team will confirm that time. Never say a time is booked.')
      when :rep_now
        'The dealership is open right now and the team can help straight away. Learn their name and, in one or two questions, ' \
          "what they are looking for, then hand off with reason ready_for_rep, saying someone from the team will be right with them. #{contact}"
      when :answer_only
        'Your job is to answer their questions. Do not ask them qualifying questions. When they ask for a person, ' \
          "want to visit, or ask something you cannot answer, hand off. #{contact}"
      else
        "Your job: answer their questions, learn what they need, and get them to visit or talk with the team. #{learn} #{contact}"
      end
    end

    # Writing an email: a follow-up by email, or answering their email.
    def email_follow_up?
      (@follow_up && @follow_up[:channel] == :email) || @reply_channel == :email
    end

    # Every model call is logged with its tokens and cost, like the other AI
    # features (ai_query_logs), per company and purpose.
    # Sonnet pricing, USD per million tokens.
    INPUT_USD_PER_MTOK = 3.0
    OUTPUT_USD_PER_MTOK = 15.0

    def log_usage(response, ms)
      input = response.dig('usage', 'input_tokens').to_i
      output = response.dig('usage', 'output_tokens').to_i
      AiQueryLog.create!(
        company_id: @company.id, location_id: @conversation.location_id,
        feature: "quinn_#{usage_purpose}", action_name: response['model'].to_s.truncate(80),
        module_key: @web ? Assistant::Settings::CHAT_MODULE_KEY : Assistant::Settings::MODULE_KEY,
        input_tokens: input, output_tokens: output, response_time_ms: ms, execution_status: 'success',
        cost_cents: ((input * INPUT_USD_PER_MTOK + output * OUTPUT_USD_PER_MTOK) / 10_000.0).round
      )
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Brain] usage log failed: #{e.message}")
    end

    def usage_purpose
      return @purpose if @purpose
      return 'chat' if @web
      return 'opener' if @opener
      return 'follow_up' if @follow_up

      @reply_channel == :email ? 'email_reply' : 'text_reply'
    end

    def style_rule
      if email_follow_up?
        'Email style: two to four short sentences in plain words. No greeting line and no signature (both are added for you). ' \
          'No lists, no emojis. A home\'s link from HOMES may be included. Put a subject line under 60 characters in subject.'
      elsif @web
        'Chat style: one to three short sentences. No lists, no emojis, no signatures.'
      else
        'Text message style: one or two short sentences, under 300 characters. No lists, no emojis, no signatures.'
      end
    end

    # A follow-up to a buyer who stopped answering. Each is written fresh;
    # the stages follow what works for others (a quick nudge, homes that fit,
    # a check-in, a polite last one).
    def missed_visit_text
      return '' unless @missed_visit
      return '' if @follow_up # the follow-up wording carries it

      "They MISSED their visit on #{@missed_visit}; they have not written. Write one short, kind text: no problem at all, " \
        'things come up, and offer two new times from OPEN TIMES. No guilt, no mention of being late. Do not hand off.'
    end

    def follow_up_text
      return '' unless @follow_up

      n = @follow_up[:number].to_i
      of = [@follow_up[:of].to_i, n].max
      stage = if n == 1 then 'a short, friendly nudge that makes it easy to reply'
              elsif n == of then 'a polite last check-in: ask whether they would like you to keep them posted or close out their request'
              elsif n.even? then 'one or two homes from HOMES that fit what they told you, by name with the price, and why they fit (use photo_home_id for one home by text)'
              else 'a light check-in on their timeline or plans, or one useful fact from the dealer facts'
              end
      "This is FOLLOW-UP #{n} of #{of}, by #{@follow_up[:channel] == :email ? 'email' : 'text'}: they have not written back since your last " \
        "message. Write #{stage}. Do not repeat what earlier messages said, do not guilt them, and end with one easy question. " \
        'Only mention homes that fit what they said. Never mention sales, specials, discounts or new arrivals unless they asked. ' \
        "Do not hand off.#{missed_follow_up_text}"
    end

    # After a missed visit, the follow-ups aim to win the visit back.
    def missed_follow_up_text
      return '' unless @missed_visit

      " They missed a visit on #{@missed_visit} and have not rebooked. Keep it kind and low pressure; " \
        "#{booking? ? 'where it fits, offer two new times from OPEN TIMES.' : 'ask whether they would like to pick a new time.'} " \
        'Never mention being late or the missed visit more than once.'
    end

    # :book, :rep_now, :answer_only or :qualify.
    def booking_mode
      @booking_mode ||= case @settings.goal
                        when 'book_always' then :book
                        when 'book_after_hours'
                          Assistant::Hours.open_now?(@company, @conversation.location || @lead.try(:location)) ? :rep_now : :book
                        when 'answer_only' then :answer_only
                        else :qualify
                        end
    end

    def follow_up_word
      return 'get back to them' if @web || email_follow_up?

      'text them'
    end

    # The dealer's own handoff choices (Quinn settings, E96).
    def dealer_handoff_rules
      rules = []
      if @settings['handoff_on_ready'] != false
        rules << 'If they say they are ready to buy, want to put down a deposit, or want to start the paperwork, hand off (reason ready_to_buy).'
      end
      rules.join(' ')
    end

    def unknown_rule
      if @settings['handoff_on_unknown'] == false
        'If you do not know, say you will check with the team and get back to them, and keep helping with anything else. Do not hand off for this.'
      else
        'If you do not know, say you will check with the team, and hand off.'
      end
    end

    def booking?
      @booking.present? && @booking.enabled?
    end

    def visit_rule
      if booking?
        return 'VISITS: you book visits yourself. When they want to visit, offer EXACTLY TWO times from OPEN TIMES in plain ' \
               'words (never the [id], never a list of more), on different days or a morning and an afternoon; if they name a ' \
               'day, offer two times that day. When they clearly accept one, set book_slot to its id. When you set book_slot or ' \
               'cancel_visit, a confirmation with the day, time and address is sent for you, so your reply must be empty or a ' \
               'few warm words that do not repeat the time (for example "Perfect, see you then."). If they ' \
               'want a time that is not listed, offer the closest listed ones. To move a booked visit, offer times and set ' \
               'book_slot for the new one. If they ask to cancel, set cancel_visit. Never say a visit is booked unless you set ' \
               'book_slot. If there are no open times, hand off (reason appointment).'
      end

      if booking_mode == :book
        'If they want to change or cancel a visit already booked, hand off. If they want a new visit, ask what day and time ' \
          'suits them first, then hand off with reason visit_time.'
      else
        'If they want to book a visit, or change or cancel one, hand off (reason appointment).'
      end
    end

    def opener_text
      return '' unless @opener

      "This is your FIRST text to them; they have not texted you yet. Say hi by first name if you have it, say you are #{@settings.assistant_name} " \
        "with #{knowledge.dealer_name}, mention what they asked about if it is recorded below, and ask one easy question that fits your goal. " \
        'Do not hand off. Do not add opt out wording; it is added for you.'
    end

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
            photo_home_id: { type: 'integer', description: 'The [number] of one home from HOMES to send its photos with your reply, when they ask for pictures or to see it.' },
            buyer_question: { type: 'string', description: 'If their latest message asks a question, that question in a few plain words. Omit if they did not ask one.' },
            question_answered: { type: 'boolean', description: 'True only if you answered their question from the facts, homes or dealer answers given to you.' },
            question_topic: { type: 'string', enum: AssistantQuestion::TOPICS },
            handoff: { type: 'boolean', description: 'True when a person should take over now.' },
            handoff_reason: { type: 'string', enum: HANDOFF_REASONS },
            summary: { type: 'string', description: 'One or two sentences for the sales rep: who this is and what they want. Use their name or "they", never he or she.' },
            subject: { type: 'string', description: 'Only for an email follow-up: the subject line, under 60 characters.' },
            book_slot: { type: 'string', description: 'The [id] from OPEN TIMES they clearly accepted, to book (or move their visit to). Omit otherwise.' },
            cancel_visit: { type: 'boolean', description: 'True only when they clearly asked to cancel their booked visit.' }
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
        text = message_text(comm).truncate(600)
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

    # The words of a text, chat message or email. An email is HTML with the
    # earlier messages quoted under it; only the new part is read.
    def message_text(comm)
      text = comm.body.to_s
      return text.strip unless comm.try(:channel) == 'email' || text.include?('</')

      text = text.gsub(%r{<br\s*/?>|</p>|</div>}i, "\n")
      text = ActionView::Base.full_sanitizer.sanitize(text).gsub('&nbsp;', ' ').gsub('&amp;', '&')
      lines = text.lines.map(&:rstrip)
      cut = lines.index { |l| l.match?(/\AOn .+wrote:\s*\z/) || l.start_with?('>') || l.match?(/\A-+\s*Original Message/i) || l.match?(/\AFrom: /) }
      lines = lines.first(cut) if cut
      lines.join("\n").squeeze("\n").strip
    end

    # Company records only, not a website: a company can hold several sites,
    # including demos built from templates that carry a sample business name
    # and footer ("Coastal Breeze Homes" answered for Summit Park on staging).
    # Texts go out under the company's name, so the facts must match it.
    def knowledge
      @knowledge ||= Concierge::Knowledge.new(website: nil, company: @company)
    end

    # Web addresses Quinn may text in this conversation (the listed homes'
    # pages, only where the number allows links). AssistantReplyJob lets these
    # through Assistant::Rules and nothing else.
    def allowed_urls
      links_allowed? ? stock.filter_map { |v| Assistant::Media.home_url(@company, v) } : []
    end

    def links_allowed?
      return @links_allowed if defined?(@links_allowed)

      # A web chat is on a web page already: home links are fine there.
      @links_allowed = @web || email_follow_up? || Assistant::Media.links_allowed?(@conversation)
    end

    # Every listed home's page, for an email (email carries links whatever
    # the texting number's registration says).
    def home_urls
      stock.filter_map { |v| Assistant::Media.home_url(@company, v) }
    end

    public :allowed_urls, :links_allowed?, :home_urls

    def website_lines
      Assistant::Sources.prompt_lines(@company)
    rescue StandardError
      ''
    end

    def faq_lines
      Array(@settings['faqs']).map { |f| "Q: #{f['q']}\n  A: #{f['a']}" }.join("\n")
    end

    def links_rule
      if links_allowed?
        'Never send a web address except a home\'s own link exactly as written in HOMES, and only when they ask for ' \
          'a link, more details or pictures. You can also send its photos with photo_home_id.'
      else
        'Never send a link or a web address of any kind. When they ask for pictures, a link or to see a home, send ' \
          'its photos with photo_home_id and say the photos are on their way.'
      end
    end

    def stock
      @stock ||= @company.vehicles.where(is_deleted: [false, nil], status: Concierge::InventorySearch::SERVABLE)
                         .order(updated_at: :desc).limit(STOCK_LIMIT).to_a
    end

    def stock_ids
      stock.map(&:id)
    end

    def stock_lines
      stock.map do |v|
        bits = ["[#{v.id}] #{[v.year, v.make, v.model].compact_blank.join(' ')}"]
        bits << "#{v.bedrooms} bed" if v.bedrooms.present?
        bits << "#{v.bathrooms.to_s.sub(/\.0\z/, '')} bath" if v.bathrooms.present?
        bits << "#{v.square_feet} sq ft" if v.square_feet.present?
        bits << "$#{v.sale_price.to_i}" if v.sale_price.to_i.positive?
        bits << (Assistant::Media.photos(v).any? ? 'has photos' : 'no photos')
        if links_allowed? && (url = Assistant::Media.home_url(@company, v))
          bits << "link #{url}"
        end
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
