# frozen_string_literal: true

module Catalog
  # Matches scraped manufacturer-catalog homes against a dealer's existing
  # vehicles so we can SUPPLEMENT (fill blanks, add images/specs) instead of
  # creating duplicates.
  #
  # Match heuristic: normalize make+model+sections on both sides. Names like
  # "Sunshine Arc (Single)" → make="sunshine", model="arc", sections=1; catalog
  # emits manufacturer="sunshine homes", model_name="Arc", dimensions implying
  # one section.
  #
  # Confidence:
  #   :high   — base-model token AND sections both match
  #   :medium — base-model token matches; sections unspecified on one side
  #   :low    — base-model token only contained in vehicle name (fuzzy)
  #   nil     — no candidate (caller treats as "would be a new ATO row")
  class SupplementMatcher
    Match = Struct.new(:home, :vehicle, :confidence, :reason, keyword_init: true)

    SIZE_WORD_TO_SECTIONS = {
      'single' => 1, 'singlewide' => 1, 'singlewides' => 1, 'sw' => 1,
      'double' => 2, 'doublewide' => 2, 'doublewides' => 2, 'dw' => 2,
      'triple' => 3, 'tw' => 3
    }.freeze

    # Stop words: English articles/conjunctions that show up in marketing names
    # ("The Genesis", "Pride of the Plains") and product noise. Without these the
    # word "the" alone caused Sunshine catalog entries to match unrelated
    # Champion vehicles whose model started with "The".
    NOISE_TOKENS = (
      SIZE_WORD_TO_SECTIONS.keys +
      %w[home homes manufactured mobile new used] +
      %w[the a an of and or] +
      %w[model floorplan floor plan series]
    ).freeze

    def initialize(company:, source:)
      @company = company
      @source  = source
    end

    # Yields one Match per parsed catalog home.
    # @return [Array<Match>]
    def call
      homes, errors = Catalog::RunService.parse_only(@source)
      Rails.logger.warn "[Catalog::SupplementMatcher] #{errors.size} parse errors" if errors.any?

      candidates = build_candidates
      homes.map { |home| match(home, candidates) }
    end

    private

    # Pre-index dealer vehicles by normalized (make_token, model_token, sections).
    # Limited to in-scope inventory (not deleted). Includes already-supplemented
    # rows so the matcher is idempotent — re-running on a stamped vehicle still
    # finds it and reports it as already-matched.
    def build_candidates
      vehicles = @company.vehicles.where(is_deleted: [false, nil]).to_a
      vehicles.map do |v|
        # ORDERED tokens (make + model, deduped, order preserved) so we can pick
        # the first numeric token as the model number. Width tokens come later
        # in the sequence and don't get confused with it.
        ordered = (tokenize(v.make) + tokenize(v.model)).uniq
        {
          vehicle: v,
          make_tokens:  tokenize(v.make),
          model_tokens: tokenize(v.model),
          ordered:      ordered,
          model_number: first_numeric(ordered),
          # Vehicle.sections is integer; nil means "unspecified".
          sections: v.sections.to_i.positive? ? v.sections.to_i : derive_sections_from_name(v)
        }
      end
    end

    def derive_sections_from_name(vehicle)
      tokens = (tokenize(vehicle.make) + tokenize(vehicle.model))
      tokens.each do |t|
        sec = SIZE_WORD_TO_SECTIONS[t]
        return sec if sec
      end
      nil
    end

    def match(home, candidates)
      # Pick the primary token sequence for model-number extraction:
      # - URL-slug source_key like "md-26-rawhide" carries the model directly
      #   (model = "26", "32" is width). Use it when it has alpha tokens.
      # - Purely numeric source_keys (Sunshine: "225015") are platform IDs, not
      #   model identifiers; fall back to model_name in that case.
      key_tokens   = tokenize(home.source_key)
      name_tokens  = tokenize(home.model_name)
      primary      = alpha(key_tokens).any? ? key_tokens : name_tokens
      home_ordered = (key_tokens + name_tokens).uniq
      home_alpha   = alpha(home_ordered).to_set
      home_nums    = numeric(home_ordered).to_set
      # Model number = first numeric in the primary sequence. This is the
      # critical disambiguator: in `md-50-32`, `50` is the model and `32` is
      # the width — matching on `32` alone would collapse every 32-foot-wide
      # variant onto the same vehicle.
      home_model_number = first_numeric(primary) || first_numeric(home_ordered)
      home_sections =
        case home.property_type
        when 'double' then 2
        when 'single' then 1
        else derive_sections(home)
        end

      scored = candidates.filter_map do |c|
        v_alpha = alpha(c[:ordered]).to_set
        v_nums  = numeric(c[:ordered]).to_set

        # Series/alpha tokens must overlap — same product family.
        next if (home_alpha & v_alpha).empty?

        # Primary key: model number. If the catalog entry has one, the vehicle
        # MUST have a matching one. If the catalog has no model number we fall
        # back to alpha-only matching (low confidence).
        if home_model_number
          next if c[:model_number].nil?
          next unless normalize_num(home_model_number) == normalize_num(c[:model_number])
        end

        sections_match = sections_compatible?(home_sections, c[:sections])
        confidence =
          if home_model_number && c[:model_number] && sections_match != :mismatch
            :high
          elsif home_model_number && c[:model_number]
            :medium # model match but sections disagree
          else
            :low    # no model number on either side — alpha only
          end

        # Score boosts confidence: matching extra numeric tokens (e.g. width)
        # is a tiebreaker when multiple candidates share the same model number.
        score = confidence_score(confidence) +
                (home_nums & v_nums).size * 3 +
                (home_alpha & v_alpha).size
        { candidate: c, confidence: confidence, score: score }
      end

      best = scored.max_by { |s| s[:score] }
      if best
        c = best[:candidate]
        Match.new(home: home, vehicle: c[:vehicle], confidence: best[:confidence],
                  reason: "model=#{home_model_number || '—'}↔#{c[:model_number] || '—'} alpha=#{(home_alpha & alpha(c[:ordered]).to_set).to_a.join(',')} sections=#{c[:sections] || 'unspec'}")
      else
        Match.new(home: home, vehicle: nil, confidence: nil, reason: 'no candidate')
      end
    end

    # Returns alpha-only tokens in their original order (caller .to_set's when needed).
    def alpha(tokens)
      tokens.reject { |t| t.match?(/\A\d+\z/) }
    end

    # Returns numeric-only tokens in their original order (caller .to_set's when needed).
    def numeric(tokens)
      tokens.select { |t| t.match?(/\A\d+\z/) }
    end

    # First numeric token (in given order). The model number is the first
    # numeric to appear in the source-key/name sequence.
    def first_numeric(tokens)
      tokens.find { |t| t.match?(/\A\d+\z/) }
    end

    # Normalize for model-number comparison: strip leading zeros so "04" and "4"
    # are treated the same.
    def normalize_num(n)
      n.to_s.sub(/\A0+(?=\d)/, '')
    end

    # Catalog source name OR config.manufacturer_name — same fallback the
    # ingestion service uses.
    def manufacturer_name
      @source.config['manufacturer_name'].presence || @source.name
    end

    def tokenize(str)
      return [] if str.blank?

      str.to_s
         .downcase
         .gsub(/[^a-z0-9 ]/, ' ')
         # Split letter↔digit boundaries so "Md20" → "md 20" and "Pri3284" →
         # "pri 3284". Otherwise the model number stays glued to the series and
         # we lose the disambiguating numeric token.
         .gsub(/([a-z])(\d)/, '\1 \2')
         .gsub(/(\d)([a-z])/, '\1 \2')
         .split
         .reject { |t| NOISE_TOKENS.include?(t) }
    end

    # :exact, :unspecified, or :mismatch
    def sections_compatible?(home_sections, vehicle_sections)
      return :unspecified if home_sections.nil? || vehicle_sections.nil?
      home_sections == vehicle_sections ? :exact : :mismatch
    end

    def derive_sections(home)
      tokens = tokenize(home.model_name)
      tokens.each do |t|
        sec = SIZE_WORD_TO_SECTIONS[t]
        return sec if sec
      end
      # ManufacturedHomes Platform adapter occasionally leaves a hint in features.
      nil
    end

    def confidence_score(level)
      { high: 100, medium: 60, low: 30 }[level]
    end
  end
end
