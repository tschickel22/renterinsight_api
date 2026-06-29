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
      %w[the a an of and or]
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
      # Source key is often the cleanest model identifier (URL slug like
      # "md-26-rawhide"); pull tokens from it AND from the parsed model_name
      # so we get the model number even when adapters truncate names.
      home_tokens = tokens_for(home.model_name) | tokens_for(home.source_key)
      home_alpha  = alpha(home_tokens)
      home_nums   = numeric(home_tokens)
      home_sections =
        case home.property_type
        when 'double' then 2
        when 'single' then 1
        else derive_sections(home)
        end

      scored = candidates.filter_map do |c|
        # Combine make+model tokens because dealers commonly shove the model
        # number into either field, and the duplication is harmless.
        v_tokens = c[:make_tokens] | c[:model_tokens]
        v_alpha  = alpha(v_tokens)
        v_nums   = numeric(v_tokens)

        # Series/alpha tokens must overlap — same product family.
        next if (home_alpha & v_alpha).empty?

        # Model-number disambiguation. If the catalog entry has a model number,
        # the vehicle MUST have a matching one — picking a random same-series
        # vehicle when there's no number to confirm is the bug that produced
        # "md-04 matches Md20" and "md-46 matches Md (Double) Md20".
        if home_nums.any?
          next if v_nums.empty?
          next if (home_nums & v_nums).empty?
        end

        sections_match = sections_compatible?(home_sections, c[:sections])
        confidence =
          if home_nums.any? && v_nums.any? && (home_nums & v_nums).any? && sections_match != :mismatch
            :high
          elsif (home_alpha & v_alpha).size >= 2 || (home_nums.any? && v_nums.any? && (home_nums & v_nums).any?)
            :medium
          else
            :low
          end

        score = confidence_score(confidence) +
                (home_nums & v_nums).size * 5 +
                (home_alpha & v_alpha).size
        { candidate: c, confidence: confidence, score: score }
      end

      best = scored.max_by { |s| s[:score] }
      if best
        Match.new(home: home, vehicle: best[:candidate][:vehicle],
                  confidence: best[:confidence],
                  reason: "alpha=#{(home_alpha & alpha(best[:candidate][:make_tokens] | best[:candidate][:model_tokens])).to_a.join(',')} num=#{(home_nums & numeric(best[:candidate][:make_tokens] | best[:candidate][:model_tokens])).to_a.join(',')} sections=#{best[:candidate][:sections] || 'unspec'}")
      else
        Match.new(home: home, vehicle: nil, confidence: nil, reason: 'no candidate')
      end
    end

    def tokens_for(str)
      tokenize(str).to_set
    end

    def alpha(tokens)
      tokens.reject { |t| t.match?(/\A\d+\z/) }.to_set
    end

    def numeric(tokens)
      tokens.select { |t| t.match?(/\A\d+\z/) }.to_set
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
