# frozen_string_literal: true

module Truebuild
  module Trueview
    # What an appliance option's name promises it looks like, in words the
    # drawing model and the checks both use. Order forms abbreviate: "20.5CF
    # O/U Refer w/o Ice" is a top-freezer refrigerator with no dispenser,
    # "21 CF Stnls SxS Refer w/ice" a stainless side-by-side with one. Left to
    # the name, a top-freezer was drawn as a side-by-side and a stainless
    # fridge in white, and both passed their check.
    module OptionLook
      module_function

      APPLIANCES = /refrigerator|\brefer\b|fridge|appliance/i

      # => "a stainless steel side-by-side refrigerator (two tall doors) with an
      # ice and water dispenser on the door", or nil when the name says nothing
      # about looks or the surface is not an appliance.
      def describe(surface, value)
        return nil unless surface.to_s.match?(APPLIANCES)

        text = value.to_s
        fridge = surface.to_s.match?(/refrigerator|\brefer\b|fridge/i) || text.match?(/\b(refer|ref|refrigerator)\b|frenchdo?o?r?ref/i)
        parts = [finish(text), (style(text) if fridge)].compact
        return nil if parts.empty?

        thing = fridge ? 'refrigerator' : 'appliances'
        look = "#{parts.join(' ')} #{thing}"
        look += style_detail(text) if fridge
        # A top-freezer "w/ Ice" has an ice maker inside, not a dispenser on
        # the door: only side-by-side and French door models show one.
        dispenser = (dispenser(text) if fridge && style(text) != 'top-freezer') || ''
        "#{look}#{dispenser}"
      end

      def finish(text)
        return 'black stainless steel' if text.match?(/black\s+(stainless|stnls|ss)\b/i)
        return 'stainless steel' if text.match?(/\b(stainless|stnls|ss)\b/i)
        return 'black' if text.match?(/\bblack\b/i)
        return 'white' if text.match?(/\bwhite\b/i)

        nil
      end

      def style(text)
        return 'French door' if text.match?(/french/i)
        return 'side-by-side' if text.match?(/\bsxs\b|side\s*by\s*side/i)
        return 'top-freezer' if text.match?(%r{\bo/u\b|over\s*/?\s*under}i)

        nil
      end

      def style_detail(text)
        case style(text)
        when 'French door' then ' (two doors on top over a freezer drawer)'
        when 'side-by-side' then ' (two tall doors side by side, freezer on one side)'
        when 'top-freezer' then ' (a freezer door on top of a larger fresh food door)'
        else ''
        end
      end

      def dispenser(text)
        return ' with no ice or water dispenser on the door' if text.match?(%r{w/o\s*ice|without\s+ice}i)
        return ' with an ice and water dispenser on the door' if text.match?(%r{w/\s*ice|with\s+ice}i)

        ''
      end
    end
  end
end
