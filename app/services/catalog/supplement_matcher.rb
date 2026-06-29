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

    NOISE_TOKENS = (SIZE_WORD_TO_SECTIONS.keys + %w[home homes manufactured mobile new used]).freeze

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
        {
          vehicle: v,
          make_tokens:  tokenize(v.make),
          model_tokens: tokenize(v.model),
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
      home_make_tokens  = tokenize(manufacturer_name)
      home_model_tokens = tokenize(home.model_name)
      home_sections     = home.property_type == 'double' ? 2 : home.property_type == 'single' ? 1 : derive_sections(home)

      # Score each candidate; pick the best.
      scored = candidates.filter_map do |c|
        next unless make_match?(home_make_tokens, c[:make_tokens])
        next unless model_match?(home_model_tokens, c[:model_tokens])

        sections_match = sections_compatible?(home_sections, c[:sections])
        confidence =
          if sections_match == :exact then :high
          elsif sections_match == :unspecified then :medium
          else :low
          end

        score = confidence_score(confidence) + (exact_model_token_match?(home_model_tokens, c[:model_tokens]) ? 1 : 0)
        { candidate: c, confidence: confidence, score: score }
      end

      best = scored.max_by { |s| s[:score] }
      if best
        Match.new(home: home, vehicle: best[:candidate][:vehicle],
                  confidence: best[:confidence],
                  reason: "make+model match, sections=#{best[:candidate][:sections] || 'unspecified'}")
      else
        Match.new(home: home, vehicle: nil, confidence: nil, reason: 'no candidate')
      end
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
         .split
         .reject { |t| NOISE_TOKENS.include?(t) }
    end

    def make_match?(home_tokens, vehicle_tokens)
      return false if home_tokens.empty? || vehicle_tokens.empty?
      # A vehicle make of "Sunshine Arc (Single)" tokenizes to [sunshine, arc].
      # We accept ANY shared token because dealers vary the make field heavily.
      (home_tokens & vehicle_tokens).any?
    end

    def model_match?(home_tokens, vehicle_tokens)
      return false if home_tokens.empty?
      # Any catalog model token appears in the vehicle's model tokens (or even
      # its make tokens — many dealers shove the model into the make field).
      home_tokens.any? { |t| vehicle_tokens.include?(t) }
    end

    def exact_model_token_match?(home_tokens, vehicle_tokens)
      home_tokens.any? && (home_tokens - vehicle_tokens).empty?
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
