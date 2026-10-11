# frozen_string_literal: true

module Guide
  # Drafts the help a change needs, for a person to review (backlog E75).
  #
  # For a new or changed place (an Atlas entry): a help article, a "What's
  # new" line, and optional in-page tour steps that may only point at markers
  # the build reports actually exist. The "show me where" part of the tour is
  # not drafted at all; it comes straight from the Atlas entry's menu path.
  #
  # For a release: release notes written from the commits, or a decision that
  # nothing in them is visible to dealers.
  class ReleaseDrafter
    SYSTEM = <<~PROMPT
      You write in-app help for {{brand}}, software that dealerships (manufactured homes, RVs) use to run their business: leads, deals, inventory, accounting, service, marketing.

      Rules:
      - Write for a dealership employee, not a developer. Plain words, short sentences, second person.
      - Only state what the material you are given supports. Never invent a menu path, button, field or setting. Describe where things are using the location you are given.
      - Write the product's name as {{brand}}. Never write a literal product name.
      - Never use em dashes or en dashes, and never a spaced hyphen as a dash ("word - word"). Use a period, comma, colon or parentheses.
      - Commit messages are written by developers: translate them into what the dealer can now do and why it helps. Leave out internal details (specs, refactors, table names, tests, file paths).
    PROMPT

    ENTRY_TOOL = {
      name: 'draft_feature_help',
      description: 'Help content for one place in the product.',
      input_schema: {
        type: 'object',
        properties: {
          article_title: { type: 'string', description: 'Task-shaped, e.g. "Run a Profit & Loss report".' },
          article_excerpt: { type: 'string', description: 'One sentence, under 160 characters.' },
          article_markdown: { type: 'string', description: 'The article body in Markdown: what it is for, how to get there, the steps, tips. Use ## headings. Do not repeat the title.' },
          whats_new: { type: 'string', description: 'One or two sentences for a What\'s New list, or empty if this change is not news to a dealer.' },
          in_page_steps: {
            type: 'array',
            description: 'Optional tour steps on the page itself, after the person arrives. Only markers from the allowed list.',
            items: {
              type: 'object',
              properties: {
                marker: { type: 'string' }, title: { type: 'string' }, text: { type: 'string' }
              },
              required: %w[marker title text]
            }
          }
        },
        required: %w[article_title article_excerpt article_markdown whats_new]
      }
    }.freeze

    RELEASE_TOOL = {
      name: 'draft_release_notes',
      description: 'Release notes for a set of commits.',
      input_schema: {
        type: 'object',
        properties: {
          user_facing: { type: 'boolean', description: 'False when nothing here changes what a dealer sees or can do.' },
          title: { type: 'string', description: 'Short headline for the release, e.g. "Land and home packages on your website".' },
          notes_markdown: { type: 'string', description: 'A short bulleted list of what dealers can now do. Empty when not user facing.' }
        },
        required: %w[user_facing title notes_markdown]
      }
    }.freeze

    def initialize(item, client: Catalog::PriceBooks::ClaudeClient)
      @item = item
      @client = client
    end

    def draft!
      @item.update!(draft_status: 'drafting', draft_error: nil)
      drafts = case @item.entity_type
               when 'release' then draft_release
               when 'gap' then draft_gap
               else draft_entry
               end
      @item.update!(drafts: drafts.deep_stringify_keys, draft_status: 'drafted')
    rescue StandardError => e
      @item.update!(draft_status: 'failed', draft_error: "#{e.class}: #{e.message}".first(1000))
      raise unless e.is_a?(Catalog::PriceBooks::ClaudeClient::Error)
    end

    private

    def snapshot
      @item.snapshot
    end

    def entry
      @item.new_value || {}
    end

    # Markers on this place's own page (or on every page), so an in-page
    # step never points at a marker that page does not have.
    def allowed_markers
      path = entry['route'].to_s.split('?').first
      on_page = (snapshot.atlas['markers'] || {}).select { |_, pages| Array(pages).include?('*') || Array(pages).include?(path) }.keys
      (Array(entry['anchors']) + on_page).uniq
    end

    def draft_entry
      result = ask(ENTRY_TOOL, entry_prompt)
      steps = Array(result['in_page_steps']).select { |s| allowed_markers.include?(s['marker'].to_s) }.first(5)
      {
        article: {
          title: clean(result['article_title']),
          excerpt: clean(result['article_excerpt']).first(240),
          content: clean(result['article_markdown'])
        },
        whats_new: clean(result['whats_new']),
        tour: { name: "Where to find #{entry['title']}", steps: where_steps + in_page(steps) }
      }
    end

    # A question people asked that the help did not answer: an article that
    # answers it from the places in the product that fit, or a note that the
    # product does not do it.
    def draft_gap
      question = @item.context['question'].presence || @item.entity_key
      places = Guide::Atlas.search(Array(snapshot.atlas['entries']), question, limit: 8)
      result = ask(ENTRY_TOOL, <<~TEXT)
        People using the product asked this and the help had no answer:
        "#{question}"

        Places in the product that may be related (title | where | what it is | how to get there):
        #{places.map { |e| "#{e['title']} | #{Array(e['breadcrumb']).join(' > ')} | #{e['description']} | #{Array(e['where']).map { |s| s['text'] }.join(' ')}" }.join("\n").presence || '(none found)'}

        Existing help articles, so you do not duplicate one:
        #{Knowledge::Article.published.limit(80).pluck(:title).join("\n")}

        Write an article that answers the question using only these places. If none of them fits, write a short article saying the product does not do this today, and leave whats_new empty. Do not invent features.
      TEXT
      {
        article: { title: clean(result['article_title']), excerpt: clean(result['article_excerpt']).first(240), content: clean(result['article_markdown']) },
        whats_new: ''
      }
    end

    def draft_release
      result = ask(RELEASE_TOOL, release_prompt)
      { user_facing: result['user_facing'] == true, title: clean(result['title']), notes: clean(result['notes_markdown']) }
    end

    # The menu walk comes from the Atlas, not the model, so it cannot point
    # anywhere that does not exist.
    def where_steps
      Array(entry['where']).map do |s|
        { route: s['route'], selector: %([data-tour="#{s['anchor']}"]), title: s['title'], content: s['text'],
          click_required: s['click'] == true }
      end
    end

    def in_page(steps)
      steps.map do |s|
        { route: entry['route'], selector: %([data-tour="#{s['marker']}"]), title: clean(s['title']), content: clean(s['text']),
          click_required: false }
      end
    end

    def entry_prompt
      before = @item.old_value
      <<~TEXT
        #{@item.change_type == 'added' ? 'A new place was added to the product.' : 'A place in the product changed.'}

        The place:
        #{JSON.pretty_generate(entry.slice('key', 'kind', 'title', 'description', 'route', 'breadcrumb', 'synonyms'))}
        #{before ? "Before the change:\n#{JSON.pretty_generate(before.slice('title', 'description', 'route', 'breadcrumb'))}\n" : ''}
        How a person gets there (menu walk):
        #{Array(entry['where']).map { |s| "- #{s['title']}: #{s['text']}" }.join("\n")}

        Commits in this release (the closest description of what was built):
        #{commit_text}

        Markers you may use for in_page_steps (exact strings; use none if none fit):
        #{allowed_markers.join(', ').presence || '(none)'}

        Existing help articles, so you do not duplicate one:
        #{Knowledge::Article.published.limit(80).pluck(:title).join("\n")}
      TEXT
    end

    def release_prompt
      <<~TEXT
        These commits went into one release of the product. Decide whether anything in them changes what a dealer sees or can do. If so, write short release notes.

        #{commit_text(all: true)}
      TEXT
    end

    def commit_text(all: false)
      commits = Array(@item.context['commits'].presence || snapshot.commits)
      commits = commits.first(all ? 40 : 25)
      return '(no commit messages available)' if commits.empty?

      commits.map { |c| "### #{c['subject']}\n#{c['body'].to_s.first(all ? 1200 : 600)}" }.join("\n\n")
    end

    def ask(tool, prompt)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @client.call(content: prompt, tool: tool, system: SYSTEM, max_tokens: 6_000,
                              temperature: 0.3, model: AiModel.for(:help))
      log(response, started)
      response[:input] || {}
    end

    # Platform cost, not a tenant's: no company, so it never counts toward
    # any dealer's AI allowance.
    def log(response, started)
      AiQueryLog.create(
        feature: 'guide_release_draft', module_key: 'knowledge', question: "#{@item.entity_type}:#{@item.entity_key}".first(500),
        execution_status: 'success', input_tokens: response[:input_tokens], output_tokens: response[:output_tokens],
        cost_cents: (Catalog::PriceBooks::ClaudeClient.cost_usd(response[:input_tokens], response[:output_tokens]) * 100).round,
        response_time_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      )
    end

    # The house rule is no em or en dashes in anything customers read.
    def clean(text)
      text.to_s
          .gsub(/\s*\u2014\s*/, ', ')
          .gsub(/\s*\u2013\s*/, ' to ')
          .gsub(/(?<=\S) - (?=\S)/, ': ') # a spaced hyphen mid-line is a dash too; list markers start a line
          .strip
    end
  end
end
