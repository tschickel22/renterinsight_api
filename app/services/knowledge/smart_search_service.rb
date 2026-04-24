# frozen_string_literal: true

module Knowledge
  class SmartSearchService
    MAX_RESULTS = 15

    STOP_WORDS = %w[
      how do i to a the an is are was were be been being
      can could should would will shall may might must
      what where when why which who whom whose
      this that these those it its my your our their
      in on at by for with from of and or not
      me we you he she they them us
      get go make find show tell help please
    ].to_set.freeze

    attr_reader :query, :user, :results, :intent_result, :steps_run

    def initialize(query, user: nil)
      @query         = query.to_s.strip
      @user          = user
      @results       = []
      @steps_run     = []
      @intent_result = nil
    end

    def search
      return [] if @query.empty?

      step1_intent_matching
      step2_alias_resolution
      step3_feature_lookup
      step4_fuzzy_text_search
      step5_fallback if @results.empty?

      deduplicate!
      record_search
      @results.first(MAX_RESULTS)
    end

    private

    # ─── Step 1: Intent matching (regex patterns) ──────────────
    def step1_intent_matching
      @steps_run << :intent
      @intent_result = IntentMatcher.new(@query).parse
    end

    # ─── Step 2: Entity alias resolution ───────────────────────
    def step2_alias_resolution
      @steps_run << :alias
      return if @intent_result&.entity.present?

      hit = Knowledge::EntityAlias
            .where('lower(alias_name) = ?', @query.downcase)
            .order(:entity_type)
            .first
      return unless hit

      @intent_result = IntentMatcher::Result.new(
        intent:     'navigate',
        entity:     hit.canonical_key,
        confidence: 0.7,
        matched_text: @query
      )
    end

    # ─── Step 3: Feature lookup from intent ────────────────────
    def step3_feature_lookup
      @steps_run << :feature
      return unless @intent_result&.matched?
      return if @intent_result.confidence < 0.5

      mod = Knowledge::Module.active.find_by(key: @intent_result.entity)
      return unless mod

      feature_key = intent_to_feature_key(@intent_result.intent)
      feature     = feature_key && mod.features.find_by(key: feature_key)

      @results << {
        type:       'navigate',
        label:      navigate_label(@intent_result.intent, mod),
        title:      navigate_label(@intent_result.intent, mod),
        description: mod.respond_to?(:description) ? mod.description.to_s : '',
        module:     mod.key,
        feature:    feature&.key,
        route:      feature&.route.presence || mod.route,
        selector:   feature&.ui_selector,
        confidence: @intent_result.confidence
      }.compact

      tour = find_tour_for_module(mod.id)
      add_tour_result(tour) if tour

      Knowledge::Article.where(is_published: true)
                        .where(knowledge_module_id: mod.id)
                        .order(:position)
                        .limit(3)
                        .each { |a| add_article_result(a) }
    end

    # ─── Step 4: Fuzzy text search across all tables ───────────
    def step4_fuzzy_text_search
      @steps_run << :fuzzy
      terms = extract_search_terms
      return if terms.empty?

      existing_module_ids = @results
        .select { |r| r[:type] == 'navigate' }
        .filter_map { |r| Knowledge::Module.active.find_by(key: r[:module])&.id }
        .to_set

      search_modules(terms, exclude_ids: existing_module_ids)

      existing_slugs = @results.select { |r| r[:type] == 'article' }.filter_map { |r| r[:slug] }.to_set
      search_articles(terms, exclude_slugs: existing_slugs)

      existing_tour_ids = @results.select { |r| r[:type] == 'tour' }.filter_map { |r| r[:tour_id] }.to_set
      search_tours(terms, exclude_ids: existing_tour_ids)
    end

    # ─── Step 5: Fallback ──────────────────────────────────────
    def step5_fallback
      @steps_run << :fallback
      @results << {
        type:  'article',
        title: "No match for \"#{@query}\"",
        label: "No match for \"#{@query}\"",
        description: "Try shorter keywords like a module name (e.g. 'leads', 'inventory', 'invoices')",
        module: 'help',
        source: 'fallback'
      }
    end

    # ═══════════════════════════════════════════════════════════
    # Fuzzy search helpers (parameterized queries — no SQL injection)
    # ═══════════════════════════════════════════════════════════

    def extract_search_terms
      words = @query.downcase.split(/[\s,.\-!?]+/)
      meaningful = words.reject { |w| STOP_WORDS.include?(w) || w.length < 2 }
      meaningful = words.reject { |w| w.length < 2 } if meaningful.empty?
      meaningful.uniq.first(5)
    end

    # Build a safe OR clause: "(col1 ILIKE ? OR col2 ILIKE ?) OR (col1 ILIKE ? OR col2 ILIKE ?)"
    # Returns [sql_string, *bind_values]
    def build_ilike_conditions(terms, columns)
      clauses = []
      binds   = []
      terms.each do |term|
        col_clauses = columns.map { |col| "#{col} ILIKE ?" }
        clauses << "(#{col_clauses.join(' OR ')})"
        columns.size.times { binds << "%#{term}%" }
      end
      [clauses.join(' OR '), *binds]
    end

    def search_modules(terms, exclude_ids: Set.new)
      sql, *binds = build_ilike_conditions(terms, %w[name key description])
      modules = Knowledge::Module.active
                                .where(sql, *binds)
                                .where.not(id: exclude_ids.to_a)
                                .limit(5)

      modules.each do |mod|
        name_lower = mod.name.to_s.downcase
        desc_lower = mod.respond_to?(:description) ? mod.description.to_s.downcase : ''
        score = terms.count { |t| name_lower.include?(t) || desc_lower.include?(t) }

        @results << {
          type:        'navigate',
          title:       "Go to #{mod.name}",
          label:       "Go to #{mod.name}",
          description: mod.respond_to?(:description) ? mod.description : nil,
          module:      mod.key,
          route:       mod.route,
          confidence:  0.4 + (score * 0.1),
        }.compact

        tour = find_tour_for_module(mod.id)
        add_tour_result(tour) if tour
      end
    end

    def search_articles(terms, exclude_slugs: Set.new)
      sql, *binds = build_ilike_conditions(terms, %w[title excerpt content])

      articles = Knowledge::Article.where(is_published: true)
                                  .where(sql, *binds)
                                  .where.not(slug: exclude_slugs.to_a)
                                  .includes(:knowledge_module)
                                  .limit(8)

      scored = articles.map do |a|
        text = "#{a.title} #{a.respond_to?(:excerpt) ? a.excerpt.to_s : ''} #{a.content.to_s}".downcase
        score = terms.count { |t| text.include?(t) }
        [a, score]
      end.sort_by { |_, s| -s }

      scored.first(5).each do |a, _|
        add_article_result(a)
      end
    end

    def search_tours(terms, exclude_ids: Set.new)
      sql, *binds = build_ilike_conditions(terms, %w[name description])

      tours = Tour.where(is_active: true)
                  .where(sql, *binds)
                  .where.not(id: exclude_ids.to_a)
                  .includes(:steps)
                  .limit(3)

      tours.each { |t| add_tour_result(t) }
    end

    # ═══════════════════════════════════════════════════════════
    # Result builders
    # ═══════════════════════════════════════════════════════════

    def add_tour_result(tour)
      @results << {
        type:        'tour',
        title:       tour.name,
        label:       "Tour: #{tour.name}",
        description: tour.respond_to?(:description) ? tour.description : nil,
        module:      tour.respond_to?(:knowledge_module) ? tour.knowledge_module&.key : nil,
        tour_id:     tour.id,
        tour_key:    tour.respond_to?(:key) ? tour.key : nil,
        steps:       tour.steps.count,
      }.compact
    end

    def add_article_result(article)
      @results << {
        type:         'article',
        title:        article.title,
        label:        article.title,
        description:  article.respond_to?(:excerpt) ? article.excerpt : nil,
        module:       article.knowledge_module&.key,
        slug:         article.slug,
        article_type: article.respond_to?(:article_type) ? article.article_type : nil,
      }.compact
    end

    def find_tour_for_module(module_id)
      Tour.where(is_active: true)
          .where(knowledge_module_id: module_id)
          .includes(:steps)
          .order(:position)
          .first
    rescue StandardError
      nil
    end

    # ═══════════════════════════════════════════════════════════
    # Helpers
    # ═══════════════════════════════════════════════════════════

    def deduplicate!
      seen = Set.new
      @results.reject! do |r|
        key = "#{r[:type]}:#{r[:slug] || r[:tour_id] || r[:route] || r[:label]}"
        seen.include?(key).tap { seen.add(key) }
      end
    end

    def intent_to_feature_key(intent)
      case intent
      when 'create' then 'create'
      when 'update' then 'update'
      when 'delete' then 'delete'
      when 'search', 'navigate' then 'list'
      end
    end

    def navigate_label(intent, mod)
      case intent
      when 'create' then "Create a new #{singularize(mod.name)}"
      when 'update' then "Edit #{mod.name}"
      when 'delete' then "Delete #{singularize(mod.name)}"
      when 'search' then "Search #{mod.name}"
      else               "Go to #{mod.name}"
      end
    end

    def singularize(name)
      name.to_s.sub(/s\z/, '').sub(/ie\z/, 'y')
    end

    def record_search
      Knowledge::Search.create!(
        user_id:         @user&.id,
        query:           @query,
        intent_detected: @intent_result&.intent,
        result_count:    @results.size,
        action_taken:    @steps_run.last.to_s
      )
    rescue StandardError => e
      Rails.logger.warn("[Knowledge::SmartSearchService] failed to log search: #{e.message}")
    end
  end
end
