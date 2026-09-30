# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Factory order forms name their sections freely: "Cabinets", "Cabinets
    # Cont.", "Carpet Colors", "(Baldwin) 2876 H42180 Swayzee". The Champion
    # Topeka book published 108 groups that way. A buyer choosing options
    # needs a short, stable list, so sections map onto the groups below, and
    # a section naming a model makes its options that model's.
    module Sections
      # [key, name, pattern] in priority order; the first match wins.
      GROUPS = [
        ['floor-plan', 'Floor Plan Options', /model specific|elevations?|dormers?|bedroom opt|floor ?plan/i],
        ['packages', 'Packages', /\bpackage|forced option|energy star/i],
        ['frame', 'Frame & Transport', /\bframes?\b|axle|hitch/i],
        ['construction', 'Construction', /construction|insulation|drywall(?! .*colou?r)|studs?|walls? ?2x/i],
        ['roofing', 'Roofing', /shingle|roof/i],
        ['exterior', 'Exterior', /exterior|siding|shutter|corner post|vinyl wallboard|4[24]00 series/i],
        ['windows-doors', 'Windows & Doors', /window|door/i],
        ['appliances', 'Kitchen & Appliances', /appliance|kitchen|range|refrig/i],
        ['bathrooms', 'Bathrooms', /bath|lav\b|shower|closet/i],
        ['cabinets', 'Cabinets', /cabinet|furniture|hw .*wrap|destin ?white|timberwolf|liberty package/i],
        ['countertops', 'Countertops', /counter ?top/i],
        ['backsplash', 'Backsplash & Tile', /backsplash|subway|tile/i],
        ['flooring', 'Flooring', /floor|carpet|lino|vinyl plank|lvp/i],
        ['interior', 'Interior Walls & Trim', /interior|accent wall|main panel|trim|vog|paint|ceiling/i],
        ['electrical', 'Electrical', /electric|lighting|fan|outlet/i],
        ['plumbing-heating', 'Plumbing & Heating', /plumb|heat|furnace|water heater|hvac|a\/c/i],
        ['fireplaces', 'Fireplaces', /fireplace/i]
      ].freeze
      OTHER = ['other', 'Other Options'].freeze

      # "(Baldwin) 2876 H42180 Swayzee" names the Baldwin, 2876H42180.
      MODEL_IN_SECTION = /(\d{4})\s*([HM])\s*(\d)\s*(\d)((?:\s?[0-9A-Z]){3})/

      module_function

      # @return [Array(String, String)] group key and display name
      def group_for(section)
        text = section.to_s
        return ['floor-plan', 'Floor Plan Options'] if model_number_in(text)

        hit = GROUPS.find { |_, _, pattern| text.match?(pattern) }
        hit ? hit.first(2) : OTHER
      end

      # A model number written into a section heading, normalized.
      def model_number_in(section)
        md = section.to_s.upcase.match(MODEL_IN_SECTION) or return nil
        candidate = "#{md[1]}#{md[2]}#{md[3]}#{md[4]}#{md[5].delete(' ')}"
        mn = Catalog::ModelNumber.parse(candidate)
        mn.valid? ? mn.normalized : nil
      end
    end
  end
end
