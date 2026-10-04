# frozen_string_literal: true

module Catalog
  module PriceBooks
    # A buyer picks one color from each set: one siding color, one shutter
    # color. Order forms title the same set a dozen ways ("Siding", "SIDING",
    # "Standard Siding", "Countertop Color", "STANDARD COUNTERTOPS T/O"), so
    # titles are reduced to a short set name.
    module ColorSets
      module_function

      SETS = [
        ['Siding', /siding|4[24]00 series/i],
        ['Shutters', /shutter/i],
        ['Countertop', /counter ?top/i],
        ['Backsplash', /backsplash|subway|\btile\b/i],
        ['Carpet', /carpet/i],
        ['Linoleum', /\blino/i],
        ['Accent wall', /accent wall/i],
        ['Main panel', /main panel/i],
        ['Cabinets', /cabinet/i],
        ['Shingles', /shingle|roof/i],
        ['Trim', /trim/i],
        ['Doors', /door/i]
      ].freeze

      def normalize(title)
        text = title.to_s
        found = SETS.find { |_, pattern| text.match?(pattern) }
        return found.first if found

        text.gsub(/\(.*?\)|\b(colou?rs?|select(ion)?|cont\.?|standard|t\/o)\b/i, ' ').squish.capitalize.presence || 'Colors'
      end
    end
  end
end
