# frozen_string_literal: true

module Guide
  # The in-app help assistant (backlog E75, phase 4; E118).
  #
  # Answers from the published help and how it works notes, the Atlas (every
  # place in the product this person can open), the dealership's own setup in
  # every module (my_setup), a few of their records (look_up, the Claude
  # connector's read tools run as this person), and a maintained list of what
  # DealerTide does and does not do (product_facts). It replies through a
  # `reply` tool, so every answer arrives with the articles it used and the
  # places it suggests, which the app turns into "Show me where" and "Go
  # there" buttons.
  #
  # Every reply has an outcome (OUTCOMES). Only no_help is a gap in the help.
  # looks_wrong and needs_support show fixed text from code and are handed to
  # support (GuideFlag); not_offered is logged as a feature request.
  #
  # It sees exactly what the person could see in the app (Tom, 2026-11-24):
  # every lookup runs with their permissions and locations.
  class Assistant
    MAX_ROUNDS = 6
    HISTORY = 12
    # Said when Claude replies without an answer: never stored empty.
    NO_ANSWER = 'I could not find an answer to that in the help. Try asking it another way, or open Help to search.'
    # Said instead of an unconfirmed "we don't offer that".
    UNCONFIRMED = "I couldn't find that in the help or the screens I can see, so I won't guess whether it can be done. " \
                  "I've noted the question so the help gets written. Support can tell you in the meantime."

    OUTCOMES = %w[answered needs_detail no_help not_offered looks_wrong needs_support].freeze

    # Fixed text for the outcomes that promise follow-up, so the model can
    # never promise something support did not.
    FIXED_ANSWERS = {
      'looks_wrong' => "I want to get this one checked properly. I've passed it to support with the details, and someone will follow up.",
      'needs_support' => "I can't make that change for you, but I've sent your request to support with the details, and someone will follow up."
    }.freeze

    SYSTEM = <<~PROMPT
      You are the help assistant inside {{brand}}, software dealerships (manufactured homes, RVs) use for leads, deals, inventory, accounting, service and marketing. You help the person in front of you use it, and you answer for THEIR account, not in general.

      How to answer:
      - Use your tools before answering: find_place for where something is, search_help for how to do it and how the product works, search_videos for a how-to.
      - When the answer depends on how this dealership set something up (how their commissions are figured, which account a payment posts to, their tax setup, their texting numbers, their agreement templates), call my_setup for that module and answer from what it returns. Say what their setup actually is, not what it could be.
      - When they ask why a particular record came out the way it did (why is this deal's tax missing, how was this commission figured, why isn't this invoice in the books, what posted this entry, where does this agreement field come from), call explain_record for it. To find or list records, use look_up. The page they are on is given at the start of the question (for example /deals/659 or /accounting/journal-entries/16); use it to find the record they mean, and ask for the number only if the page does not show it.
      - When they ask whether {{brand}} can do something, or how to do something you find no article for, call find_place and product_facts before answering. A button, page or action find_place returns means it can be done: say where. Say "{{brand}} doesn't do that today" ONLY when product_facts returns it with offered false, then give the nearest thing it does, and use outcome not_offered. Never say it cannot be done because the help has no article on it.
      - Answer only from what the tools return and what the person told you. Never invent a menu path, button, field, report, setting or number. If the tools do not cover it, say plainly that you do not know and use outcome no_help. Do not guess, and do not offer a possible cause the tools did not give: when two figures do not agree and the tools do not say why, say that they differ and that you are passing it to support (outcome looks_wrong).
      - If you need one more thing from them to answer (which deal, which location), ask one short question and use outcome needs_detail.
      - Never say something is broken, a bug, or not working. If what they describe does not match what the help, the product or their own setup says, use outcome looks_wrong and put what looked off in assistant_reason.
      - You cannot change anything. Whenever they ask you (or support) to change, load, move, set up or fix something for them, the outcome is needs_support, even if you also find they can do it themselves. Put what they want done in assistant_reason. The person is shown a fixed message that support will follow up, so do not write steps in answer_markdown for needs_support.
      - Bookkeeping: you may explain general bookkeeping (what an accrual is, how a customer deposit is usually treated) from your own knowledge, but every {{brand}} step, screen and account must come from the tools. Do not add any disclaimer to an answer about their setup or how {{brand}} works. Only when you give general tax or legal guidance, add one short line that it is not tax or legal advice.
      - The help includes "How it works" notes on the rules behind the screens (how deals, invoices and payments post, what commission is paid on). For how something is figured or posted, search for them and answer from them, not from general knowledge.
      - Use this dealership's own words for things (my_account your_terms).
      - Be brief: a short answer, then numbered steps if there are steps. Speak to the person as "you".
      - Never use em dashes or en dashes, or a spaced hyphen as a dash. Use a period, comma, colon or parentheses.
      - If a tool says the person's role does not include something, tell them that and that their admin can help. Never work around it.
      - Always finish by calling reply.
    PROMPT

    def self.tools
      @tools ||= [
        {
          name: 'find_place',
          description: 'Find pages, reports, settings and actions in the product by what they are for. Returns places this person can open, with where they sit in the menu.',
          input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
        },
        {
          name: 'search_help',
          description: 'Search the published help articles and how it works notes. Returns the best matches with their text.',
          input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
        },
        {
          name: 'search_videos',
          description: 'Search the training videos (title, chapters and what the narrator says). Returns matching videos with the moment that covers the question.',
          input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
        },
        {
          name: 'my_account',
          description: "A short summary of this dealership: their terms for things, deal stages, locations, users, connections (QuickBooks, website, texting, email) and what is on their plan.",
          input_schema: { type: 'object', properties: {} }
        },
        {
          name: 'my_setup',
          description: "How this dealership set up one module, read with this person's permissions. Modules: #{Guide::SetupAreas.catalog}.",
          input_schema: { type: 'object', properties: { module: { type: 'string', enum: Guide::SetupAreas.keys } }, required: ['module'] }
        },
        {
          name: 'look_up',
          description: "Read this dealership's records, as this person (their permissions and locations), at most 20 rows a call. " \
                       "Pick one tool and pass its arguments:\n#{Guide::LookUp.catalog}",
          input_schema: {
            type: 'object',
            properties: { tool: { type: 'string', enum: Guide::LookUp.tools.keys }, arguments: { type: 'object' } },
            required: ['tool']
          }
        },
        {
          name: 'explain_record',
          description: 'Why one record came out the way it did, read as this person: a deal (its lines, tax, gross, ' \
                       'whether and how it posted, money in, and its commission line by line with the plan used), a ' \
                       'journal_entry (its lines and what posted it), an invoice or payment (whether it is in the books, ' \
                       'and why not), a bank_transaction (how it was booked), or an agreement (where each field gets its ' \
                       'value and which signer fills it). Use it for "why is", "how was this figured", "where does this come from".',
          input_schema: {
            type: 'object',
            properties: { type: { type: 'string', enum: Guide::ExplainRecord::TYPES }, id: { type: 'string', description: 'The record number, like 659' } },
            required: %w[type id]
          }
        },
        {
          name: 'product_facts',
          description: 'Whether the product does something, and the nearest thing it does when it does not. Call before saying it cannot do something.',
          input_schema: { type: 'object', properties: { topic: { type: 'string' } }, required: ['topic'] }
        },
        {
          name: 'reply',
          description: 'Your answer to the person. Call this exactly once, last.',
          input_schema: {
            type: 'object',
            properties: {
              answer_markdown: { type: 'string' },
              outcome: {
                type: 'string', enum: OUTCOMES,
                description: 'answered: you answered it. needs_detail: you asked them one question. no_help: the tools did not cover it. ' \
                             'not_offered: product_facts says the product does not do it. looks_wrong: what they describe does not match ' \
                             'the help, the product or their setup. needs_support: they asked you to change something.'
              },
              assistant_reason: { type: 'string', description: 'For looks_wrong, needs_support and not_offered: one sentence on what looked off or what they want.' },
              article_slugs: { type: 'array', items: { type: 'string' }, description: 'Slugs of articles your answer used.' },
              place_keys: { type: 'array', items: { type: 'string' }, description: 'Up to 3 place keys from find_place the person should go to, most useful first.' },
              videos: {
                type: 'array', description: 'Up to 2 training videos from search_videos worth watching, with where to start.',
                items: { type: 'object', properties: { id: { type: 'integer' }, start: { type: 'integer' } }, required: ['id'] }
              }
            },
            required: %w[answer_markdown outcome]
          }
        }
      ].freeze
    end

    Result = Struct.new(:answer, :articles, :places, :videos, :outcome, :assistant_reason, :trace,
                        :input_tokens, :output_tokens, :cache_read_tokens, keyword_init: true) do
      # answered: true/false, the shape before outcomes, still works.
      def initialize(answered: nil, **attrs)
        attrs[:outcome] ||= answered == false ? 'no_help' : 'answered' unless answered.nil?
        attrs[:trace] ||= []
        super(**attrs)
      end

      def answered
        outcome == 'answered'
      end
    end

    # data_assistant: whether this company has the AI Assistant (the sparkle
    # in the header), which answers questions about its own records.
    def initialize(user:, company:, client: Guide::ClaudeChat.new, data_assistant: nil)
      @user = user
      @company = company
      @client = client
      @data_assistant = data_assistant.nil? ? (AiQueryLog.monthly_limit_for(company, user: user).positive? rescue false) : data_assistant
      @seen_articles = {}
      @seen_places = {}
      @seen_videos = {}
      @trace = []
      @not_offered_seen = false
    end

    # Reports, totals and lists of many records belong to the AI Assistant
    # (or to a report). Help reads a few records to explain or check them.
    def data_rule
      if @data_assistant
        "- look_up is for a few records. For a report, a total across many records, a chart or an export (how many leads this month, sales by rep, unpaid invoices), say that the AI Assistant, the sparkle icon at the top of the screen, answers questions about their data, and use outcome answered.\n"
      else
        "- look_up is for a few records. For a report, a total across many records or an export (how many leads this month, sales by rep, unpaid invoices), use find_place to point them to the report or list that shows it, and use outcome answered.\n"
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
      @usage = Hash.new(0)
      system = Guide::Copy.render(SYSTEM + data_rule, company: @company)

      MAX_ROUNDS.times do
        response = @client.call(system: system, messages: messages, tools: self.class.tools)
        add_usage(response['usage'] || {})
        content = Array(response['content'])

        reply = content.find { |c| c['type'] == 'tool_use' && c['name'] == 'reply' }
        return finish(reply['input']) if reply

        uses = content.select { |c| c['type'] == 'tool_use' }
        if uses.empty?
          text = content.select { |c| c['type'] == 'text' }.map { |c| c['text'] }.join("\n")
          return finish({ 'answer_markdown' => text, 'outcome' => text.present? ? 'answered' : 'no_help' })
        end

        messages << { role: 'assistant', content: content }
        messages << { role: 'user', content: uses.map { |u| { type: 'tool_result', tool_use_id: u['id'], content: run_tool(u).to_json } } }
      end

      finish({ 'answer_markdown' => 'I could not finish looking that up. Try asking it a different way.', 'outcome' => 'no_help' })
    end

    private

    def framed(question, page)
      return question.to_s if page.blank?

      "(I am on the page #{page.to_s.first(200)}.)\n\n#{question}"
    end

    # Cached input is billed at a tenth, writing the cache at 1.25 times, so
    # input_tokens is the uncached equivalent and the existing cost math holds.
    def add_usage(usage)
      @usage[:input] += usage['input_tokens'].to_i
      @usage[:output] += usage['output_tokens'].to_i
      @usage[:cache_write] += usage['cache_creation_input_tokens'].to_i
      @usage[:cache_read] += usage['cache_read_input_tokens'].to_i
    end

    def billed_input_tokens
      (@usage[:input] + (@usage[:cache_write] * 1.25) + (@usage[:cache_read] * 0.1)).round
    end

    def app_ctx
      @app_ctx ||= Guide::AppContext.new(user: @user, company: @company)
    end

    def run_tool(use)
      input = use['input'] || {}
      result =
        case use['name']
        when 'find_place' then find_place(input['query'].to_s)
        when 'search_help' then search_help(input['query'].to_s)
        when 'search_videos' then search_videos(input['query'].to_s)
        when 'my_account' then Guide::AccountState.new(@user, @company).to_h
        when 'my_setup' then Guide::SetupAreas.new(app_ctx).call(input['module'])
        when 'look_up' then Guide::LookUp.new(app_ctx).call(input['tool'], input['arguments'])
        when 'explain_record' then Guide::ExplainRecord.new(app_ctx).call(input['type'], input['id'])
        when 'product_facts' then product_facts(input['topic'])
        else { error: 'unknown tool' }
        end
      record_trace(use['name'], input, result)
      result
    rescue StandardError => e
      Rails.logger.warn("[Guide::Assistant] #{use['name']} failed: #{e.class} #{e.message}")
      record_trace(use['name'], input, { error: 'failed' })
      { error: 'That lookup failed.' }
    end

    def record_trace(name, input, result)
      @trace << { 'tool' => name, 'input' => input, 'result' => result.to_json.first(1_500) }
    end

    def product_facts(topic)
      facts = Guide::ProductFacts.call(topic)
      @not_offered_seen ||= Array(facts[:matches]).any? { |m| m[:offered] == false }
      facts
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
          text: Guide::Copy.render("#{a.excerpt}\n\n#{Knowledge::Screenshot.strip(a.content)}", company: @company).to_s.first(2_500) }
      end
    end

    # Videos this person can open in the help center's Videos tab.
    def search_videos(query)
      admin = @user.respond_to?(:platform_admin?) && (@user.platform_admin? || @user.super_admin?)
      TrainingVideo.search(query, scope: TrainingVideo.visible(admin: admin)).map do |video, moment|
        @seen_videos[video.id] = video
        { id: video.id, title: video.title, start: moment[:start], chapter: moment[:label],
          length: video.duration_seconds, about: video.description.to_s.first(300) }
      end
    end

    # An older reply shape (answered: true/false) still maps to an outcome.
    def outcome_of(input)
      outcome = input['outcome'].to_s
      return outcome if OUTCOMES.include?(outcome)
      return 'no_help' if input.key?('answered') && input['answered'] == false

      'answered'
    end

    # Only articles and places the tools actually returned are passed on, so a
    # made-up slug or key never becomes a link.
    def finish(input)
      outcome = outcome_of(input)
      answer = clean(input['answer_markdown'])
      # "We don't offer that" only on the maintained list's word. When the list
      # did not say so, the claim goes too, not just the outcome: on staging
      # "how do I delete a deal" showed "DealerTide does not offer a way to
      # delete a deal" while Delete was on every deal.
      if !@not_offered_seen && (outcome == 'not_offered' || claims_not_offered?(answer))
        outcome = 'no_help'
        answer = UNCONFIRMED
      end
      outcome = 'no_help' if outcome == 'answered' && answer.blank?
      answer = FIXED_ANSWERS[outcome] if FIXED_ANSWERS.key?(outcome)

      articles = Array(input['article_slugs']).filter_map { |s| @seen_articles[s] }.uniq.first(4)
      places = Array(input['place_keys']).filter_map { |k| @seen_places[k] }.uniq.first(3)
      videos = Array(input['videos']).filter_map do |v|
        video = @seen_videos[v['id'].to_i] if v.is_a?(Hash)
        video && { id: video.id, title: video.title, start: v['start'].to_i.clamp(0, video.duration_seconds.to_i) }
      end.uniq { |v| v[:id] }.first(2)

      Result.new(
        answer: answer.presence || NO_ANSWER,
        articles: articles.map { |a| { slug: a.slug, title: Guide::Copy.render(a.title, company: @company) } },
        places: places.map { |e| { key: e['key'], title: e['title'], kind: e['kind'], route: e['route'] } },
        videos: videos, outcome: outcome, assistant_reason: input['assistant_reason'].to_s.first(1_000).presence,
        trace: @trace, input_tokens: billed_input_tokens, output_tokens: @usage[:output], cache_read_tokens: @usage[:cache_read]
      )
    end

    # "DealerTide does not offer a way to...": a claim the product cannot do
    # something, whatever outcome it came with. About the product only, never
    # a record ("it doesn't have a selling price" is a fact about a deal).
    def claims_not_offered?(answer)
      brand = Regexp.escape(Brand.current(company: @company).name.to_s)
      answer.to_s.match?(/(#{brand}|the system|the app|the software)\s+(does not|doesn't|cannot|can't)\s+(offer|support|allow|let you|have a way)/i)
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
