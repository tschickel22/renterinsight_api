# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Which homes an option price row applies to, from evidence the factory
    # prints rather than the model's reading alone. The first Champion book
    # showed why: no row carried a series, so Aspire-only options appeared on
    # every series; "Sect" options on the Aspire DW tab were read as single
    # section; and "SW<=60' box" lost its band.
    #
    # Order of trust: the tab (a series tab is that series; SW and DW tabs are
    # single and multi section), then the option's own name, then the model.
    # "DW" inside a name means drywall ("Partial DW"), so names never use it.
    module Applicability
      module_function

      GENERIC_TAB = /master|option list|all series|announce/i
      TAB_NOISE = /\b(?:20\d{2}|HUD|MOD(?:ULAR)?|SW|DW|MW|singles?|sectionals?|model specific|opts?|options?|factory|price list|net)\b|[-_]/i
      SINGLE_NAME = /\bSW\b|single ?wide|single section/i
      MULTI_NAME = /\bsect(?:ional)?s?\b|multi ?section|\bmulti\b/i

      # tab: the sheet name; series_list: the manufacturer's plan series.
      # Returns attributes to assign on the CatalogOptionPrice.
      def resolve(name:, tab:, series_list:, model_specific: false, ai: {})
        attrs = {
          'series' => model_specific ? nil : series_for(tab, series_list),
          'section_type' => section_type(name, tab) || ai['section_type'].presence_in(CatalogOptionPrice::SECTION_TYPES),
          'width_ft' => (ai['width_ft'].to_i if ai['width_ft'].to_i.between?(8, 36))
        }
        min, max = length_band(name)
        if min || max
          attrs['min_length_ft'] = min
          attrs['max_length_ft'] = max
        else
          attrs['min_length_ft'] = ai['box_length_min_ft']
          attrs['max_length_ft'] = ai['box_length_max_ft']
        end
        attrs
      end

      # "2025 Aspire DW" is Aspire; "Prime - Decatur factory" is Prime Of
      # Indiana; "2023 DGAE HUD" is DGAE, a series with no plans here, so its
      # options reach no home rather than every home.
      def series_for(tab, series_list)
        return nil if tab.blank? || tab.match?(GENERIC_TAB)

        known = series_list.compact.find do |s|
          words = s.downcase.split - %w[champion of the homes]
          words.any? { |w| tab.downcase.match?(/\b#{Regexp.escape(w)}\b/) }
        end
        known || tab.gsub(TAB_NOISE, ' ').squish.titleize.presence
      end

      def section_type(name, tab)
        from_tab = Keys.section_type_from_tab(tab.to_s.sub(/model specific.*/i, ''))
        return from_tab if from_tab

        single = name.to_s.match?(SINGLE_NAME)
        multi = name.to_s.match?(MULTI_NAME)
        return 'single' if single && !multi
        return 'multi' if multi && !single

        nil
      end

      # 48-56' => 48..56, <48' => ..47, <=60' => ..60, >66' => 67.., >=60' => 60..
      def length_band(name)
        s = name.to_s
        if (m = s.match(/(\d{2})\s*'?\s*(?:-|to)\s*(\d{2})\s*'/i))
          return [m[1].to_i, m[2].to_i]
        end
        if (m = s.match(/(<=|>=|≤|≥|<|>)\s*(\d{2})\s*'/))
          n = m[2].to_i
          return case m[1]
                 when '<' then [nil, n - 1]
                 when '<=', '≤' then [nil, n]
                 when '>' then [n + 1, nil]
                 else [n, nil]
                 end
        end
        [nil, nil]
      end
    end
  end
end
