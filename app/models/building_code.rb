# frozen_string_literal: true

# The code a home was built to, which is not its style. A double wide can be a
# HUD-code manufactured home or a modular home; a dealer selling both wants a
# Modular page on their site that shows only the modular ones.
#
#   HUD      built to the federal HUD code (a "manufactured home")
#   MOD      built to the state or local building code (a "modular home")
#   ANSI     a park model, built to ANSI A119.5 rather than HUD
#   HUD_MOD  a plan the factory builds either way ("HUD or MOD" in Champion's
#            feed, "Modular or Manufactured" in Cavco's)
#
# Every feed words this differently, so .from_label reads all of them into one
# code. Stored on vehicles.building_code; CatalogPlanVariant keeps its own
# HUD/MOD column for price books.
module BuildingCode
  HUD     = 'HUD'
  MOD     = 'MOD'
  ANSI    = 'ANSI'
  HUD_MOD = 'HUD_MOD'

  ALL = [HUD, MOD, ANSI, HUD_MOD].freeze

  LABELS = {
    HUD     => 'Manufactured (HUD)',
    MOD     => 'Modular',
    ANSI    => 'Park Model (ANSI)',
    HUD_MOD => 'Manufactured or Modular'
  }.freeze

  module_function

  # A feed's wording, or one of our codes, to a code. nil when it says nothing
  # about the code: "Single Wide" is a size, and guessing HUD from it would put
  # a modular home on the wrong page.
  def from_label(value)
    text = value.to_s.strip
    return nil if text.empty?
    return text.upcase if ALL.include?(text.upcase)

    text = text.downcase
    return HUD_MOD if text.match?(/\b(hud or mod(ular)?|mod(ular)? or (hud|manufactured)|manufactured or modular)\b/)
    return ANSI    if text.match?(/\b(park model|ansi|rpth)\b/)
    return MOD     if text.match?(/\bmod(ular)?\b/)
    return HUD     if text.match?(/\b(hud|manufactured)\b/)

    nil
  end

  # The first label in the list that names a code.
  def from_labels(values)
    Array(values).each do |value|
      code = from_label(value)
      return code if code
    end
    nil
  end

  # The stored codes a filter for these codes should match. A home the factory
  # builds either way belongs on both the HUD and the Modular page.
  def matching(codes)
    wanted = Array(codes).flat_map { |c| c.to_s.split(',') }.filter_map { |c| from_label(c) }.uniq
    wanted += [HUD_MOD] if wanted.intersect?([HUD, MOD])
    wanted.uniq
  end

  def label(code)
    LABELS[code]
  end
end
