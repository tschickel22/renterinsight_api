# frozen_string_literal: true

module Guide
  # Drafts a product tour from a goal ("Teach a new rep to start a deal and
  # send a quote") using only places and markers that exist (backlog E75,
  # phase 5). The earlier AI tours failed because they guessed CSS selectors;
  # this one picks from the Atlas's menu walks and the build's data-tour
  # markers, and anything else it names is dropped. The draft is checked
  # against the live app and edited in the recorder before it is saved.
  class TourDrafter
    TOOL = {
      name: 'draft_tour',
      description: 'A guided tour made of steps from the allowed list.',
      input_schema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'Short, task-shaped, e.g. "Start a deal and send a quote".' },
          description: { type: 'string', description: 'One sentence shown in the Help menu.' },
          steps: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                place_key: { type: 'string', description: 'Use the menu walk of this place (steps to reach it). Omit when using marker.' },
                marker: { type: 'string', description: 'A data-tour marker on the page given in route. Omit when using place_key.' },
                route: { type: 'string', description: 'For a marker step: the page it is on.' },
                click: { type: 'boolean', description: 'For a marker step the person must press to reach the next step (opening a dialog, choosing a type, a Next button).' },
                title: { type: 'string' },
                text: { type: 'string', description: 'One or two sentences.' }
              },
              required: %w[title text]
            }
          }
        },
        required: %w[name description steps]
      }
    }.freeze

    SYSTEM = <<~PROMPT
      You design short guided tours for {{brand}}, software dealerships use for leads, deals, inventory, accounting, service and marketing.
      - A tour walks a person through one real task, in the order they would do it, and ends when the task is done. Nothing else: no detours to other areas, no "you can also" steps, never the same place twice.
      - For a tour about creating something (a lead, a deal, a calendar event), start with its action place (keys beginning action:), which already includes clicking the New button. Then point at the form's own markers in the order a person fills them in, and end on the form's save marker. Nothing comes after the save.
      - Pick at most 5 fields: the ones a person must fill in to finish. Skip optional and advanced fields.
      - When a marker has to be pressed for the next part to appear (choosing a type card, opening a dialog, a Next button), set click to true on it.
      - At most 12 steps in all.
      - Use only the places and markers you are given. A place_key step expands into the clicks that reach that place, so you do not need separate steps for the menu.
      - A marker step points at something on the page the tour has just reached: put it right after the place_key step for that page, with that page as its route.
      - Write for a dealership employee: plain words, second person, short. Never use em dashes, en dashes or a spaced hyphen as a dash.
      - Never describe a button or field you were not given.
      - Never name a button, menu item or field by its words: dealers rename them. Say "the highlighted button", "this field", "this menu item" and describe what it does.
    PROMPT

    def initialize(goal, client: Catalog::PriceBooks::ClaudeClient)
      @goal = goal.to_s.strip
      @client = client
      snapshot = Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE).order(snapshot_at: :desc).first
      # Tours are for dealers: places only platform admins see are left out
      # (the nightly check, signed in as a dealer, caught a tour sending
      # people to the admin-only Lot Map).
      @entries = Array(snapshot&.atlas&.dig('entries')).reject { |e| platform_only?(e) }.index_by { |e| e['key'] }
      @markers = snapshot&.atlas&.dig('markers') || {}
      @marker_labels = snapshot&.atlas&.dig('marker_labels') || {}
    end

    def draft
      raise ArgumentError, 'Describe what the tour should teach.' if @goal.blank?
      raise ArgumentError, 'No feature map yet; the release watcher has not read a build.' if @entries.empty?

      result = @client.call(content: prompt, tool: TOOL, system: Guide::Copy.render(SYSTEM), max_tokens: 4_000,
                            temperature: 0.3, model: AiModel.for(:help))[:input] || {}
      { name: clean(result['name']), description: clean(result['description']), steps: expand(Array(result['steps'])) }
    end

    private

    def expand(steps)
      # The sidebar is an accordion: opening a section closes the one before.
      open_section = nil
      # The page the person is on after the steps so far. An in-page step must
      # be on it: the model once met the other rules by sending an inventory
      # tour to the Leads page for a table called "Browse your stock".
      here = nil
      steps.flat_map do |s|
        if s['place_key'].present? && (entry = @entries[s['place_key']])
          here = entry['route'].to_s.split('?').first
          # Clicking the section that is already open would close it and hide
          # the next step, so that click is left out. Any other section is
          # clicked: an earlier one has been closed by whatever opened since.
          walk_steps = Array(entry['where']).reject do |w|
            next false unless w['anchor'].to_s.start_with?('nav-section:')

            already_open = w['anchor'] == open_section
            open_section = w['anchor']
            already_open
          end
          walk = walk_steps.map do |w|
            { route: w['route'], selector: %([data-tour="#{w['anchor']}"]), title: w['title'], content: w['text'], click_required: w['click'] == true }
          end
          # The model's words describe the place; they go on the last step of
          # the walk. An action's own clicks already say exactly what to press
          # ("Choose Add Individual"), so those keep their words.
          walk[-1] = walk[-1].merge(title: clean(s['title']), content: clean(s['text'])) if walk.any? && entry['kind'] != 'action'
          walk
        elsif s['marker'].present? && here.present? && s['route'].to_s.split('?').first == here &&
              marker_on_page?(s['marker'], s['route'])
          [{ route: s['route'], selector: self.class.selector_for(s['marker']), title: clean(s['title']), content: clean(s['text']), click_required: s['click'] == true }]
        else
          [] # names something that does not exist: dropped, never guessed
        end
      end.chunk_while { |a, b| a[:selector] == b[:selector] }.map(&:first) # never the same element twice in a row
         .then { |all| end_at_save(all) }
         .then { |all| fit(all) }
         .each_with_index.map { |s, i| s.merge(position: i + 1) }
    end

    MAX_STEPS = 12

    def save_step?(step)
      step[:selector].to_s.match?(/:save\b|:save-/)
    end

    # The task is done at the save: anything after it is a detour.
    def end_at_save(steps)
      i = steps.index { |s| save_step?(s) }
      i ? steps.first(i + 1) : steps
    end

    # Too long: drop the last plain field steps before the save, never the
    # walk in, a step that must be clicked, or the save itself.
    def fit(steps)
      steps = steps.dup
      while steps.size > MAX_STEPS
        i = steps.rindex { |s| !s[:click_required] && !save_step?(s) && s[:selector].to_s.match?(/form:|\[id=/) }
        break unless i

        steps.delete_at(i)
      end
      steps.first(MAX_STEPS + 3)
    end

    # atlas.json says which pages each marker is on ('*' for every page).
    # Builds from before that recorded source files instead, which say
    # nothing about pages, so those markers are not used.
    def marker_on_page?(marker, route)
      pages = Array(@markers[marker])
      path = route.to_s.split('?').first
      pages.include?('*') || pages.include?(path)
    end

    # A data-tour marker, or '#id' for a form field found by its label.
    def self.selector_for(marker)
      marker.to_s.start_with?('#') ? %([id="#{marker.delete_prefix('#')}"]) : %([data-tour="#{marker}"])
    end

    def platform_only?(entry)
      Array(entry['requires']).any? do |r|
        r['adminOnly'] || r['settingsAccess'] == 'platformAdmin' || r['integrationsSub'] == 'platform'
      end
    end

    def known_page?(route)
      route.present? && @entries.values.any? { |e| e['route'].to_s.split('?').first == route.to_s.split('?').first }
    end

    def prompt
      places = @entries.values.map { |e| Guide::Copy.render_deep(e) }
                       .map { |e| "#{e['key']} | #{e['title']} | #{Array(e['breadcrumb']).join(' > ')} | #{e['description']}" }
      markers = @markers.filter_map do |m, pages|
        pages = Array(pages).select { |p| p.start_with?('/', '*') }
        label = @marker_labels[m].present? ? %( "#{@marker_labels[m]}") : ''
        "#{m}#{label} (on #{pages.include?('*') ? 'every page' : pages.join(', ')})" if pages.any?
      end
      <<~TEXT
        Goal for the tour: #{@goal}

        Places (key | title | where | what it is):
        #{places.join("\n")}

        In-page markers and the pages they are on; a marker step must use one of its pages as route.
        Markers starting with # are form fields, shown with the field's label:
        #{markers.join("\n").presence || '(none)'}
      TEXT
    end

    def clean(text)
      text.to_s.gsub(/\s*—\s*/, ', ').gsub(/\s*–\s*/, ' to ').gsub(/(?<=\S) - (?=\S)/, ': ').strip
    end
  end
end
