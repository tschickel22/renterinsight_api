# frozen_string_literal: true

module Truebuild
  # A display color for a finish the factory names but does not picture, so
  # the designer can paint its drawn exterior and kitchen. Close to the real
  # product, not a match for it: the buyer sees the finish's name beside it.
  module ColorSwatches
    module_function

    NAMED = {
      # Siding
      'wedgewood' => '#6f8394', '4200 series wedgewood' => '#6f8394', 'brunswick' => '#5b605c',
      '4400 series shadow brunswick' => '#555a56', 'cream' => '#ece2c8', 'flint' => '#7c7b75', 'gray' => '#9c9fa1',
      'olive' => '#878760', 'clay' => '#c8b89a', 'white' => '#f6f6f3',
      # Shutters
      'black' => '#1f1f1f', 'blue' => '#2e4a6b', 'green' => '#37553f', 'wine' => '#692533',
      # Shingles
      'black weatherwood' => '#3b3a37', 'arch shingles black weatherwood' => '#3b3a37', 'dual black' => '#252525',
      # Cabinets and trim
      'artic white' => '#f3f3f1', 'destin white' => '#eeebe4', 'rustic walnut' => '#6a4931', 'timberwolf' => '#8a867e',
      # Countertops
      'bronzite' => '#6b5a4b', 'carrara marble' => '#ebe9e5', 'deep springs' => '#595e62', 'desert springs' => '#c9b9a1',
      'drama marble' => '#dcd8d1', 'glacier quartzite' => '#e6e7e5', 'lisola' => '#d8d2c6', 'quartz frost' => '#f0f0ee',
      # Carpet and walls
      'brentwood' => '#8e8473', 'dune' => '#c3b399', 'greige' => '#a7a096', 'rum cream' => '#d7cbb3',
      'casper cashmere' => '#d8cec1', 'dogwood harvest' => '#b4a48c', 'jurupa' => '#9a8b7a', 'patton beach' => '#cec3af'
    }.freeze

    KEYWORDS = [
      [/white|ice|frost|snow/, '#f3f3f0'], [/cream|ivory|almond/, '#ece2c8'], [/beige|tan|sand|desert|wicker/, '#cdbd9f'],
      [/gris|grey|gray|smoke|pewter|silver|slate/, '#9a9b99'], [/charcoal|graphite|onyx/, '#3d3e3f'], [/black/, '#1f1f1f'],
      [/navy|midnight/, '#253650'], [/blue/, '#40607f'], [/green|sage|olive/, '#5e6e52'], [/red|wine|burgundy|barn/, '#7a2e2e'],
      [/brown|walnut|espresso|mocha|chestnut/, '#5f4431'], [/oak|maple|natural|honey/, '#b58b5b'], [/marble|quartz/, '#e4e2de']
    ].freeze

    def hex(name)
      key = name.to_s.downcase.gsub(/\(.*?\)/, '').gsub(/\b\d+\s*oz\b/, '').squish
      NAMED[key] || KEYWORDS.find { |pattern, _| key.match?(pattern) }&.last
    end
  end
end
