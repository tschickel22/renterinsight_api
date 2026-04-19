# frozen_string_literal: true

module Knowledge
  # Matches a free-text user query against the curated regex patterns in
  # knowledge_intent_patterns and extracts a likely entity (module/feature key)
  # from the query text itself.
  #
  # Usage:
  #   Knowledge::IntentMatcher.new("how do I create a new lead").parse
  #   # => { intent: "create", entity: "leads", confidence: 0.8, pattern_id: 42 }
  #
  # Confidence is a rough 0..1 score:
  #   - 0.9 pattern match + entity in canonical keys (exact)
  #   - 0.7 pattern match + entity resolved via alias table (exact)
  #   - 0.7 short bare-noun query + exact entity (inferred navigate)
  #   - 0.6 pattern match + fuzzy entity (typo-corrected)
  #   - 0.5 pattern match only (no entity found)
  #   - 0.5 short bare-noun query + fuzzy entity
  #   - 0.3 entity found but no pattern match
  #   - 0.0 nothing matched
  class IntentMatcher
    Result = Struct.new(:intent, :entity, :confidence, :pattern_id, :matched_text, keyword_init: true) do
      def matched?
        intent.present? || entity.present?
      end

      def to_h
        super.compact
      end
    end

    def initialize(query)
      @query = query.to_s.strip
    end

    def parse
      return empty_result if @query.empty?

      pattern_hit = best_pattern
      entity      = detect_entity

      intent     = pattern_hit&.intent_type
      # If the matched pattern pinned an entity (e.g. "report" → 'reports'), prefer that.
      entity   ||= pattern_hit&.entity_key

      # A short query with no verb but a clear entity ("home", "prospect list")
      # is an implicit navigate. Bumps confidence so the search pipeline will
      # actually route it somewhere instead of dropping to the AI fallback.
      if intent.nil? && entity.present? && short_noun_query?
        intent = 'navigate'
      end

      confidence = score(
        pattern_hit,
        entity,
        inferred_navigate: intent == 'navigate' && pattern_hit.nil?,
        fuzzy: @fuzzy_match
      )

      Result.new(
        intent:       intent,
        entity:       entity,
        confidence:   confidence,
        pattern_id:   pattern_hit&.id,
        matched_text: @query
      )
    end

    private

    # Walk patterns in priority order, stop at first regex hit.
    def best_pattern
      Knowledge::IntentPattern.ordered_by_priority.find { |p| p.matches?(@query) }
    end

    # Entity detection:
    # 1) Direct match on a canonical module key (e.g. "leads", "invoices")
    # 2) Alias table resolution (e.g. "prospect" → "leads", "team member" → "users")
    # 3) Fuzzy fallback via Levenshtein — catches typos like "leed", "invioce"
    # Longer aliases are checked first so "team member" wins over bare "team".
    def detect_entity
      lowered = @query.downcase
      @fuzzy_match = false

      direct = Knowledge::Module.active.pluck(:key).find { |k| word_boundary_hit?(lowered, k.tr('_', ' ')) }
      return direct if direct

      aliases = Knowledge::EntityAlias.pluck(:alias_name, :canonical_key)
                                      .sort_by { |a, _| -a.length }
      aliases.each do |alias_name, canonical|
        return canonical if word_boundary_hit?(lowered, alias_name.downcase)
      end

      fuzzy = fuzzy_match_entity(lowered)
      if fuzzy
        @fuzzy_match = true
        return fuzzy
      end

      nil
    end

    # Only consider reasonably long candidates — short aliases like "po" or "rv"
    # would false-match against almost any typo. Same reasoning for query tokens.
    FUZZY_MIN_LEN = 4

    # Typo-tolerant entity match. For each query token (>= FUZZY_MIN_LEN chars,
    # not a common verb), compute Levenshtein distance against every candidate
    # (module keys + single-word aliases). Keep the smallest distance that
    # passes the threshold; return the canonical key for that candidate.
    def fuzzy_match_entity(lowered_text)
      tokens = lowered_text.split(/\s+/).reject { |t| t.length < FUZZY_MIN_LEN || VERB_TOKENS.include?(t) }
      return nil if tokens.empty?

      # Build candidate pool: module keys + single-word aliases. Multi-word
      # aliases are excluded because fuzzy-matching a multi-word needle against
      # a single token is meaningless.
      module_keys = Knowledge::Module.active.pluck(:key)
      alias_pairs = Knowledge::EntityAlias.pluck(:alias_name, :canonical_key)
                                          .reject { |a, _| a.include?(' ') || a.length < FUZZY_MIN_LEN }

      candidates = module_keys.map { |k| [k, k] } + alias_pairs
      best = nil

      tokens.each do |token|
        candidates.each do |needle, canonical|
          # Compare token to both the needle and its singular form so "leed"
          # matches candidate "leads" (distance from "lead" = 1).
          [needle, needle.sub(/s\z/, '')].uniq.each do |form|
            next if form.length < FUZZY_MIN_LEN
            d = levenshtein(token, form)
            # Use <= on both bounds: <= 2 absolute and <= word.length/2 relative.
            # The original spec used strict < on the ratio but that rejects
            # reasonable 4-char typos like "dael"→"deal" (distance 2, length 4),
            # which is exactly the kind of user typo we want to catch.
            next unless d <= 2 && d <= token.length / 2
            best = [d, canonical] if best.nil? || d < best.first
          end
        end
      end

      best && best.last
    end

    # Iterative two-row Levenshtein. Not the prettiest, but avoids the gem and
    # the allocation overhead of a full m×n matrix.
    def levenshtein(a, b)
      m, n = a.length, b.length
      return n if m.zero?
      return m if n.zero?
      d = Array.new(m + 1) { |i| i }
      (1..n).each do |j|
        prev = d[0]
        d[0] = j
        (1..m).each do |i|
          temp = d[i]
          d[i] = if a[i - 1] == b[j - 1]
                   prev
                 else
                   [prev, d[i], d[i - 1]].min + 1
                 end
          prev = temp
        end
      end
      d[m]
    end

    def word_boundary_hit?(text, needle)
      return false if needle.blank?
      # Strip a trailing 's' from the needle ('leads' -> 'lead') and allow an
      # optional 's' in the text, so "lead" matches canonical "leads" and vice
      # versa. Prevents "home" from matching "homework" via the \b anchors.
      root = needle.downcase.sub(/s\z/, '')
      Regexp.new('\b' + Regexp.escape(root) + 's?\b').match?(text)
    rescue RegexpError
      false
    end

    def score(pattern, entity, inferred_navigate: false, fuzzy: false)
      # Fuzzy entity matches are less trustworthy — cap below exact-match scores
      # but still above the fallback threshold so the pipeline will route them.
      if fuzzy && entity
        return 0.6 if pattern
        return 0.5 if inferred_navigate
        return 0.3
      end

      return 0.9 if pattern && entity && Knowledge::Module.active.where(key: entity).exists?
      return 0.7 if pattern && entity
      return 0.7 if inferred_navigate && entity  # short bare-noun query
      return 0.5 if pattern
      return 0.3 if entity
      0.0
    end

    # "home", "leads", "prospect list" — 1-3 tokens with no obvious verb.
    VERB_TOKENS = %w[create add new make edit update change delete remove find
                     search show where what how explain help open navigate configure setup].freeze

    def short_noun_query?
      tokens = @query.downcase.split(/\s+/)
      return false if tokens.empty? || tokens.size > 3
      (tokens & VERB_TOKENS).empty?
    end

    def empty_result
      Result.new(intent: nil, entity: nil, confidence: 0.0, pattern_id: nil, matched_text: @query)
    end
  end
end
