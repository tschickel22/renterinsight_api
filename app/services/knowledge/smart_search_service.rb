# frozen_string_literal: true

module Knowledge
  # Five-step search pipeline that goes from free (regex + aliases) to expensive
  # (embeddings → LLM fallback). Each step is only run if the previous one
  # didn't produce a confident-enough answer. Cost discipline matters: the
  # first two steps handle the majority of real-world queries for free.
  #
  # Result shape:
  #   [
  #     { type: 'navigate', label: 'Go to Leads', route: '/crm/leads', ... },
  #     { type: 'tour',     label: 'Tour: Add your first lead', tour_id: 7, ... },
  #     { type: 'article',  label: 'How to create a lead', slug: 'create-lead', ... }
  #   ]
  class SmartSearchService
    MIN_NAVIGATE_CONFIDENCE = 0.6
    ARTICLE_LIMIT           = 5

    attr_reader :query, :user, :results, :intent_result, :steps_run

    def initialize(query, user: nil)
      @query         = query.to_s.strip
      @user          = user
      @results       = []
      @steps_run     = []
      @intent_result = nil
    end

    # Runs the pipeline and returns the result array. Also persists a
    # knowledge_searches row for analytics.
    def search
      return [] if @query.empty?

      step1_intent_matching
      step2_alias_resolution
      step3_feature_lookup

      if @results.empty?
        step4_semantic_search
        step5_ai_fallback if @results.empty?
      end

      record_search
      @results
    end

    private

    # -------------------------------------------------------------------------
    # Step 1: Intent matching (FREE) — regex patterns against the query
    # -------------------------------------------------------------------------
    def step1_intent_matching
      @steps_run << :intent
      @intent_result = IntentMatcher.new(@query).parse
    end

    # -------------------------------------------------------------------------
    # Step 2: Entity alias resolution (FREE) — mostly done inside the matcher,
    # but if the user typed a bare synonym ("home" / "prospect") with no verb,
    # we still want to return a navigate result.
    # -------------------------------------------------------------------------
    def step2_alias_resolution
      @steps_run << :alias
      return if @intent_result&.entity.present?

      # Try stripping to a bare alias — single-word or two-word queries.
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

    # -------------------------------------------------------------------------
    # Step 3: Feature lookup — turn (intent, entity) into concrete navigate/tour
    # actions using the knowledge graph.
    # -------------------------------------------------------------------------
    def step3_feature_lookup
      @steps_run << :feature
      return unless @intent_result&.matched?
      return if @intent_result.confidence < MIN_NAVIGATE_CONFIDENCE

      mod = Knowledge::Module.active.find_by(key: @intent_result.entity)
      return unless mod

      feature_key = intent_to_feature_key(@intent_result.intent)
      feature     = feature_key && mod.features.find_by(key: feature_key)

      # Navigate result — always present if we know the module.
      @results << {
        type:       'navigate',
        label:      navigate_label(@intent_result.intent, mod),
        module:     mod.key,
        feature:    feature&.key,
        route:      feature&.route.presence || mod.route,
        selector:   feature&.ui_selector,
        confidence: @intent_result.confidence
      }.compact

      # Offer a matching tour if one exists for this module + intent.
      tour = Tour.active.where(knowledge_module_id: mod.id).ordered.first
      if tour
        @results << {
          type:    'tour',
          label:   "Tour: #{tour.name}",
          tour_id: tour.id,
          tour_key: tour.key,
          steps:   tour.steps.count
        }
      end

      # Include any published articles tied to the module.
      articles = Knowledge::Article.published
                                   .where(knowledge_module_id: mod.id)
                                   .ordered
                                   .limit(3)
      articles.each do |a|
        @results << {
          type:    'article',
          label:   a.title,
          slug:    a.slug,
          excerpt: a.excerpt,
          article_type: a.article_type
        }
      end
    end

    # -------------------------------------------------------------------------
    # Step 4: Semantic search over article embeddings (PAID — embedding call)
    # -------------------------------------------------------------------------
    def step4_semantic_search
      @steps_run << :semantic
      embedding = EmbeddingService.generate(@query)
      return if embedding.blank?

      articles = EmbeddingService.search(embedding, limit: ARTICLE_LIMIT)
      articles.each do |a|
        @results << {
          type:    'article',
          label:   a.title,
          slug:    a.slug,
          excerpt: a.excerpt,
          article_type: a.article_type,
          source: 'semantic'
        }
      end
    end

    # -------------------------------------------------------------------------
    # Step 5: AI fallback (MOST EXPENSIVE) — a placeholder that synthesizes a
    # "we didn't find a match, but here's a suggestion" response. Plug your
    # LLM call here when ready; we intentionally don't call anything by default
    # so tests stay hermetic and this service never accidentally bills you.
    # -------------------------------------------------------------------------
    def step5_ai_fallback
      @steps_run << :ai_fallback
      @results << {
        type:  'suggestion',
        label: "I couldn't find a direct match. Try rephrasing, or ask in support.",
        source: 'fallback'
      }
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------
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
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Knowledge::SmartSearchService] failed to log search: #{e.message}")
    end
  end
end
