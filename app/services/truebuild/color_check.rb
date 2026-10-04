# frozen_string_literal: true

module Truebuild
  # Flags a finish whose name and dot disagree: a "Black" shutter with a
  # light tan dot, a "Destin White" cabinet with a gray one. Only clear
  # contradictions are flagged; a name with no color word in it is left be.
  module ColorCheck
    module_function

    RULES = [
      [/\b(black|charcoal|onyx|ebony|espresso)\b/i, ->(l, _c, _h) { l > 45 }, 'is named black but its dot is light'],
      [/\b(white|snow|ice|frost|arctic|artic|ivory|cream)\b/i, ->(l, _c, _h) { l < 62 }, 'is named white or cream but its dot is dark'],
      [/\b(blue|navy)\b/i, ->(_l, c, h) { c < 8 || !h.between?(190, 300) }, 'is named blue but its dot is not'],
      [/\b(red|wine|burgundy|cranberry|barn red)\b/i, ->(_l, c, h) { c < 12 || h.between?(70, 320) }, 'is named red but its dot is not'],
      [/\b(green|olive|sage|hunter)\b/i, ->(_l, c, h) { c < 6 || !h.between?(80, 200) }, 'is named green but its dot is not']
    ].freeze

    # The problem as a phrase, or nil.
    def problem(name, hex)
      return nil if hex.blank?

      l, c, h = lch(hex)
      RULES.each { |re, wrong, says| return says if name.to_s.match?(re) && wrong.call(l, c, h) }
      nil
    end

    # CIE L*C*h from a hex color (D65, sRGB).
    def lch(hex)
      r, g, b = hex.delete('#').scan(/../).map { |x| x.to_i(16) / 255.0 }.map { |v| v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
      x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
      y = (r * 0.2126 + g * 0.7152 + b * 0.0722)
      z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
      f = ->(t) { t > 0.008856 ? t**(1.0 / 3) : (7.787 * t) + (16.0 / 116) }
      l = 116 * f.call(y) - 16
      a = 500 * (f.call(x) - f.call(y))
      bb = 200 * (f.call(y) - f.call(z))
      [l, Math.sqrt(a**2 + bb**2), (Math.atan2(bb, a) * 180 / Math::PI) % 360]
    end
  end
end
