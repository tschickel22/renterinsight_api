# frozen_string_literal: true

module Guide
  # The in-app help assistant (backlog E75, phase 4).
  #
  # Answers "how do I" and "where is" questions from three sources only: the
  # published help articles, the Atlas (every place in the product this person
  # can open) and this account's own setup. It looks things up with tools,
  # then replies through a `reply` tool so every answer arrives with the
  # articles it used and the places it suggests, which the app turns into
  # "Show me where" and "Go there" buttons.
  #
  # When nothing it found answers the question it says so instead of guessing,
  # and the question is logged as unanswered so it shows up as a gap to write
  # help for.
  class Assistant
    MAX_ROUNDS = 5
    HISTORY = 12
    # Said when Claude replies without an answer: never stored empty.
    NO_ANSWER = 'I could not find an answer to that in the help. Try asking it another way, or open Help to search.'

    SYSTEM = <<~PROMPT
      You are the help assistant inside {{brand}}, software dealerships (manufactured homes, RVs) use for leads, deals, inventory, accounting, service and marketing. You help the person in front of you use it.

      How to answer:
      - Use your tools before answering a how-to or where-is question: find_place for where something is, search_help for how to do it, my_account when the answer depends on how this dealership is set up.
      - Answer only from what the tools return and what the person told you. Never invent a menu path, button, field, report or setting. If the tools do not cover it, say plainly that you do not know and suggest contacting support. Do not guess.
      - Use this dealership's own words for things (my_account your_terms) and their own setup (deal stages, locations, connections) when it matters.
      - Be brief: a short answer, then numbered steps if there are steps. Speak to the person as "you".
      - Never use em dashes or en dashes, or a spaced hyphen as a dash. Use a period, comma, colon or parentheses.
      - You cannot change anything in the account. If they want something done, tell them where to do it.
      - Always finish by calling reply.
    PROMPT

    TOOLS = [
      {
        name: 'find_place',
        description: 'Find pages, reports, settings and actions in the product by what they are for. Returns places this person can open, with where they sit in the menu.',
        input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
      },
      {
        name: 'search_help',
        description: 'Search the published help articles. Returns the best matches with their text.',
        input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
      },
      {
        name: 'my_account',
        description: "How this dealership is set up: their terms for things, deal stages, locations, users, connections (QuickBooks, website, texting, email) and what is on their plan.",
        input_schema: { type: 'object', properties: {} }
      },
      {
        name: 'reply',
        description: 'Your answer to the person. Call this exactly once, last.',
        input_schema: {
          type: 'object',
          properties: {
            answer_markdown: { type: 'string' },
            article_slugs: { type: 'array', items: { type: 'string' }, description: 'Slugs of articles your answer used.' },
            place_keys: { type: 'array', items: { type: 'string' }, description: 'Up to 3 place keys from find_place the person should go to, most useful first.' },
            answered: { type: 'boolean', description: 'False when the tools did not cover the question.' }
          },
          required: %w[answer_markdown answered]
        }
      }
    ].freeze

    Result = Struct.new(:answer, :articles, :places, :answered, :input_tokens, :output_tokens, keyword_init: true)

    # data_assistant: whether this company has the AI Assistant (the sparkle
    # in the header), which answers questions about its own records.
    def initialize(user:, company:, client: Guide::ClaudeChat.new, data_assistant: nil)
      @user = user
      @company = company
      @client = client
      @data_assistant = data_assistant.nil? ? (AiQueryLog.monthly_limit_for(company, user: user).positive? rescue false) : data_assistant
      @seen_articles = {}
      @seen_places = {}
    end

    # Questions about the dealership's own records (which deals, how many
    # leads) are not help. Point them where they can be answered instead of
    # guessing.
    def data_rule
      if @data_assistant
        "- You cannot look up this dealership's records or numbers. When asked for them (which deals, how many leads, unpaid invoices), say that the AI Assistant, the sparkle icon at the top of the screen, answers questions about their data, and call reply with answered true.\n"
      else
        "- You cannot look up this dealership's records or numbers. When asked for them (which deals, how many leads, unpaid invoices), use find_place to point them to the report or list that shows it, and call reply with answered true.\n"
      end
    end

    # history: earlier [{ 'role', 'content' }] turns; page: where the person is.
    def ask(question, history: [], page: nil)
      # An empty turn is refused by the API and would fail every later question.
      messages = Array(history).last(HISTORY).map { |m| { role: m['role'], content: m['content'].to_s } }
                               .reject { |m| m[:content].strip.empty? }
      messages.shift while messages.first && messages.first[:role] != 'user'
      messages.pop while messages.last && messages.last[:role] == 'user'
      messages << { role: 'user', content: framed(question, page) }
      tokens_in = 0
      tokens_out = 0

      MAX_ROUNDS.times do
        response = @client.call(system: Guide::Copy.render(SYSTEM + data_rule, company: @company), messages: messages, tools: TOOLS)
        tokens_in += response.dig('usage', 'input_tokens').to_i
        tokens_out += response.dig('usage', 'output_tokens').to_i
        content = Array(response['content'])

        reply = content.find { |c| c['type'] == 'tool_use' && c['name'] == 'reply' }
        return finish(reply['input'], tokens_in, tokens_out) if reply

        uses = content.select { |c| c['type'] == 'tool_use' }
        if uses.empty?
          text = content.select { |c| c['type'] == 'text' }.map { |c| c['text'] }.join("\n")
          return finish({ 'answer_markdown' => text, 'answered' => text.present? }, tokens_in, tokens_out)
        end

        messages << { role: 'assistant', content: content }
        messages << { role: 'user', content: uses.map { |u| { type: 'tool_result', tool_use_id: u['id'], content: run_tool(u).to_json } } }
      end

      finish({ 'answer_markdown' => "I could not finish looking that up. Try asking it a different way.", 'answered' => false }, tokens_in, tokens_out)
    end

    private

    def framed(question, page)
      return question.to_s if page.blank?

      "(I am on the page #{page.to_s.first(200)}.)\n\n#{question}"
    end

    def run_tool(use)
      input = use['input'] || {}
      case use['name']
      when 'find_place' then find_place(input['query'].to_s)
      when 'search_help' then search_help(input['query'].to_s)
      when 'my_account' then Guide::AccountState.new(@user, @company).to_h
      else { error: 'unknown tool' }
      end
    rescue StandardError => e
      Rails.logger.warn("[Guide::Assistant] #{use['name']} failed: #{e.class} #{e.message}")
      { error: 'That lookup failed.' }
    end

    def visible_places
      @visible_places ||= Guide::Atlas.new(@user, @company).visible
    end

    def find_place(query)
      words = query.downcase.scan(/[a-z0-9&]+/).reject { |w| w.length < 2 }
      return [] if words.empty?

      scored = visible_places.map do |e|
        title = e['title'].to_s.downcase
        other = [e['synonyms'], e['breadcrumb'], e['description']].flatten.compact.join(' ').downcase
        score = words.sum { |w| (title.include?(w) ? 3 : 0) + (other.include?(w) ? 1 : 0) }
        [e, score]
      end
      scored.select { |_, s| s.positive? }.sort_by { |_, s| -s }.first(6).map do |e, _|
        @seen_places[e['key']] = e
        { key: e['key'], kind: e['kind'], title: e['title'], where: Array(e['breadcrumb']).join(' > '),
          description: e['description'], how_to_get_there: Array(e['where']).map { |s| s['text'] } }
      end
    end

    def search_help(query)
      Guide::HelpSearch.call(query).map do |a|
        @seen_articles[a.slug] = a
        { slug: a.slug, title: Guide::Copy.render(a.title, company: @company),
          text: Guide::Copy.render("#{a.excerpt}\n\n#{a.content}", company: @company).to_s.first(2_500) }
      end
    end

    # Only articles and places the tools actually returned are passed on, so a
    # made-up slug or key never becomes a link.
    def finish(input, tokens_in, tokens_out)
      articles = Array(input['article_slugs']).filter_map { |s| @seen_articles[s] }.uniq.first(4)
      places = Array(input['place_keys']).filter_map { |k| @seen_places[k] }.uniq.first(3)
      answer = clean(input['answer_markdown'])
      Result.new(
        answer: answer.presence || NO_ANSWER,
        articles: articles.map { |a| { slug: a.slug, title: Guide::Copy.render(a.title, company: @company) } },
        places: places.map { |e| { key: e['key'], title: e['title'], kind: e['kind'], route: e['route'] } },
        answered: answer.present? && input['answered'] != false,
        input_tokens: tokens_in, output_tokens: tokens_out
      )
    end

    def clean(text)
      text.to_s
          .gsub(/\s*—\s*/, ', ')
          .gsub(/\s*–\s*/, ' to ')
          .gsub(/(?<=\S) - (?=\S)/, ': ')
          .strip
    end
  end
end
