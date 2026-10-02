# frozen_string_literal: true

module Truebuild
  # Options a buyer picks one of: the same option except for its fuel
  # ("Stainless Steel Package - Gas" / "- Electric") or its package number or
  # letter ("Appliance Package 1 - Black" / "2" / "A"). Order forms carry no
  # exclusion rules, and the names are the only evidence.
  #
  # Deliberately narrow. Names that differ by room ("Crescent Edging - Kitchen"
  # / "- Utility") are additive, and a wrong exclusion stops a buyer choosing
  # something they can have, which is worse than a rep fixing a combination at
  # quote time. Only a difference on one of these axes, or one of the SINGLE
  # items below, makes a family.
  module OptionFamilies
    module_function

    FUEL = /\b(gas|electric|elec)\b/
    PACKAGE = /\b(package|pkg)\s*#?\s*([0-9]|[a-e])\b/

    # A kitchen gets one appliance package, whichever line it comes from:
    # Appliance Package 1 - Black, Stainless Steel Package - Gas, Black
    # Appliance Package, Ultimate Kitchen 2 - Package 1.
    APPLIANCE_PACKAGE = /\b(appliance|stainless|ultimate kitchen)\b.*\b(package|pkg)\b|\bultimate kitchen\b/
    # And one refrigerator, whichever fridge an upgrade replaces: Bay Port's
    # book swaps out an 18.2, a 20.5 and a 21, and keyed by those a buyer
    # could put three refrigerators in one kitchen.
    FRIDGE_SWAP = /\b(refer|ref|refrigerator|frenchdoorref|frenchdrref)\b.*\bipo\s+[0-9.]+/

    # Things a home has exactly one of, so every upgrade of it replaces the
    # others. Each rule is written against real order-form names, and
    # anything priced per room, per window or each stays additive.
    SINGLE = [
      # "102 - Std FP", "109-CrnrRsdHearthFP Full Stone", "DF006 - DW FP W/ Bookcases",
      # "Optional Odyssey Fireplace". Not "Stacked Linen FP Timberwolf" (FP is the finish).
      ['fireplace', /\A\s*(\d{3}|df\d{3})\s*-.*(fp|fireplace)\b|\bfireplace\b/],
      # Whole-home carpet: "38oz Carpet IPO 15oz - SW", "15oz Mantra IPO 13oz Sect",
      # or none at all ("Lino T/O IPO Carpet", "Omit carpet and pad T/O").
      ['carpet upgrade', /\A\s*\d+\s*oz\s+(carpet|mantra)\b.*\bipo\b|\blino t\/o ipo carpet\b|\bomit carpet\b/],
      # Cabinet material or color in place of the standard wrapped or hardwood:
      # "HW Ozark Shadow IPO Wrapped", "Mixed Cabinets IPO HW".
      ['cabinet finish', /\A(?!.*\btrim\b).*\bipo\s*(wrap|wrapped|hw)\b/],
      ['water heater', /\A\s*\d+\s*gal\b.*\bipo\b/],
      ['furnace', /\bfurn(ace)?\b.*\bipo\b|furnipo/],
      # "D23 - Exterior Elevation", "S10 - SW elevation", "Ext Elevation 4A - 28'W - 5/12".
      ['exterior elevation', /\belevation\b/],
      ['siding line', /\A\s*\d{4}\s+series\s+siding\b/],
      ['roof pitch', /\b\d+\/12\s*ipo\s*\d+\/12\b/]
    ].freeze
    ADDITIVE = /\bper\b|\beach\b|hardwood stiles/

    # The family key, or nil when the name has no fuel or package axis.
    def key(name)
      text = name.to_s.downcase.gsub(/\(.*?\)/, ' ')
      unless text.match?(ADDITIVE)
        single = SINGLE.find { |_, re| text.match?(re) }
        return single.first if single
      end
      return 'appliance package' if text.match?(APPLIANCE_PACKAGE) && !text.match?(/discount|omit/)
      return 'refrigerator' if text.match?(FRIDGE_SWAP)

      keyed = text.gsub(FUEL, '{fuel}').gsub(PACKAGE, '\\1 {pkg}')
      return nil if keyed == text

      keyed.squish.gsub(/\A[\s-]+|[\s-]+\z/, '')
    end

    # option id => family key, for options sharing a key with at least one other.
    def for(options)
      options.group_by { |o| key(o.name) }.reject { |k, os| k.nil? || os.size < 2 }
             .flat_map { |k, os| os.map { |o| [o.id, k] } }.to_h
    end
  end
end
