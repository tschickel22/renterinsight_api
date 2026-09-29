# frozen_string_literal: true

module Catalog
  # A factory model number such as 2856H32392: box width 28, length 56,
  # H (HUD) or M (modular), 3 beds, 2 baths, plan 392.
  #
  # The code is a claim, not the truth. Champion's own sheets print 30' wide
  # boxes as 32 in the code, and a scanned Prime sheet lists Apex with 4 beds
  # under a 3-bed code. `conflicts_with` reports those disagreements so the
  # importer can flag them for review instead of silently picking one.
  class ModelNumber
    PATTERN = /\A(\d{2})(\d{2})([HM])(\d)(\d)([0-9A-Z]{3})\z/

    attr_reader :raw, :normalized

    def self.parse(value)
      new(value)
    end

    # Scanned sheets confuse O and 0. The first seven characters are digits and
    # a building code letter, so only the plan suffix is ambiguous, and there a
    # letter O is always a misread zero (Prime prints both PO1 and P01).
    def self.normalize(value)
      v = value.to_s.upcase.gsub(/\s+/, '')
      return v if v.length < 8

      v[0, 7] + v[7..].tr('O', '0')
    end

    def initialize(value)
      @raw = value.to_s.strip
      @normalized = self.class.normalize(@raw)
      @match = PATTERN.match(@normalized)
    end

    def valid?
      !@match.nil?
    end

    def width_ft = valid? ? @match[1].to_i : nil
    def length_ft = valid? ? @match[2].to_i : nil
    def building_code = valid? ? (@match[3] == 'H' ? 'HUD' : 'MOD') : nil
    def beds = valid? ? @match[4].to_i : nil
    def baths = valid? ? @match[5].to_i : nil
    def plan_code = valid? ? @match[6] : nil

    # Same floor plan built to another code: 2856H32392 <-> 2856M32392.
    def sibling_code
      return nil unless valid?

      @normalized.sub(/\A(\d{4})([HM])/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2) == 'H' ? 'M' : 'H'}" }
    end

    # Printed facts that disagree with the code, e.g.
    #   conflicts_with(width_ft: 30, beds: 3) => [{ field: :width_ft, printed: 30, code: 32 }]
    def conflicts_with(printed)
      return [] unless valid?

      %i[width_ft length_ft beds baths building_code].filter_map do |field|
        value = printed[field]
        next if value.blank?

        coded = public_send(field)
        same = field == :building_code ? value.to_s.upcase == coded : value.to_f == coded.to_f
        { field: field, printed: value, code: coded } unless same
      end
    end

    def to_s = @normalized
  end
end
