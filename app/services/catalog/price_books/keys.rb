# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Stable identities, so the same option in next year's book is recognised
    # as the same option. Champion order forms carry no option codes.
    module Keys
      module_function

      # The canonical group (see Sections), so "Cabinets" and "Cabinets Cont."
      # are one group and the same option keeps its identity between books.
      def group(section)
        Sections.group_for(section).first
      end

      # Comparisons are spelled out first: "SW<=60' box" and "SW >60' box"
      # are two options, and parameterize alone makes them one.
      def option(section, description)
        "#{group(section)}--#{describe_comparisons(description).parameterize[0, 90]}"
      end

      def describe_comparisons(text)
        text.to_s.gsub(/<=|≤/, ' lte ').gsub(/>=|≥/, ' gte ').gsub('<', ' lt ').gsub('>', ' gt ').gsub('+', ' plus ')
      end

      # "56' Belvidere" is the Belvidere plan at 56 feet; a list with no names
      # (Aspire singles) uses the series and plan code, as Champion's site does.
      def plan_name(model_name, series, model_number)
        name = model_name.to_s.sub(/\A\s*\d{2}\s*'\s*/, '').strip
        return name.titleize if name.present?

        "#{series} #{Catalog::ModelNumber.parse(model_number).plan_code}".strip
      end

      # "ASPIRE HUD - 28' SECTIONAL" and "ASPIRE MODULAR" are both Aspire.
      def series(header_series, plant)
        base = header_series.to_s.split(/\s+-\s+|\b(?:HUD|MOD|MODULAR|SECTIONALS?|SINGLES?|SINGLE SECTION|NET|PRICE LIST)\b/i).first.to_s.strip
        (base.presence || plant.to_s).titleize
      end

      # Order form tabs name their section type ("Aspire DW", "Aspire SW").
      def section_type_from_tab(tab)
        return 'single' if tab.to_s.match?(/\b(SW|singles?|single section)\b/i)
        return 'multi' if tab.to_s.match?(/\b(DW|sect(ional)?s?|multi)\b/i)

        nil
      end
    end
  end
end
