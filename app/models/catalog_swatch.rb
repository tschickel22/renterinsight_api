# frozen_string_literal: true

# One finish sample from a factory decor sheet: the picture of the actual
# cabinet door, countertop or siding, and its measured color. TrueView shows
# it to the image model so a rendering matches the real finish, not a guess
# from its name.
class CatalogSwatch < ApplicationRecord
  belongs_to :manufacturer
  belongs_to :factory, optional: true
  belongs_to :catalog_swatch_sheet, optional: true

  validates :set_name, :name, :image_url, presence: true

  # Caption words that are not part of the finish's name: "Casper Cashmere
  # Main Panel", "Chai Oak Shaker Door", "Fog Optional".
  # Catalog wording around a tile or board name: "1 Row Ceramic Inhale
  # Gris", "2 Rows Catch Ice (subway)", "Inhale Gris 4 x 12".
  NOISE = /\b(main panel|accent|optional|standard|shaker door|door|panel|ceramic|subway|tile|\d+ rows?)\b|\d+\s*x\s*\d+/i

  def self.key(name)
    name.to_s.downcase.gsub(/\(.*?\)/, ' ').gsub(NOISE, ' ').gsub(/[^a-z0-9]+/, ' ').squish
  end

  # Same name, or one name inside the other when the shorter has at least
  # two words: "inhale gris" in "inhale gris ceramic", never "white" in
  # "sunset falls white".
  def self.names_match?(a, b)
    return true if a == b

    short, long = [a, b].minmax_by(&:length)
    short.split.size >= 2 && " #{long} ".include?(" #{short} ")
  end

  # The sample for a finish on a home: same manufacturer, the plant's own
  # sheet first, matched by name; when a name sits in several sets (White
  # siding, White shutters) the surface decides, and a tie is no match.
  def self.for_finish(manufacturer_id:, factory_id:, surface:, value:)
    want = key(value)
    return nil if want.empty?

    found = where(manufacturer_id: manufacturer_id, factory_id: [factory_id, nil].uniq).to_a
              .select { |s| names_match?(key(s.name), want) }
    return nil if found.empty?

    words = surface.to_s.downcase.scan(/[a-z]{4,}/).map { |w| w.sub(/s\z/, '') }
    fitting = found.select { |s| words.any? { |w| s.set_name.downcase.include?(w) } }
    fitting = found if fitting.empty? && found.map { |s| key(s.name) }.uniq.size == 1 && found.map(&:set_name).uniq.size == 1
    fitting = fitting.select { |s| s.factory_id == factory_id } if factory_id && fitting.any? { |s| s.factory_id == factory_id }
    fitting.size == 1 ? fitting.first : fitting.min_by { |s| (key(s.name).length - want.length).abs } if fitting.any?
  end
end
