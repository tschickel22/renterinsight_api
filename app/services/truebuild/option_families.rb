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
  # quote time. Only a difference on one of these axes makes a family.
  module OptionFamilies
    module_function

    FUEL = /\b(gas|electric|elec)\b/
    PACKAGE = /\b(package|pkg)\s*#?\s*([0-9]|[a-e])\b/

    # A kitchen gets one appliance package, whichever line it comes from:
    # Appliance Package 1 - Black, Stainless Steel Package - Gas, Black
    # Appliance Package, Ultimate Kitchen 2 - Package 1.
    APPLIANCE_PACKAGE = /\b(appliance|stainless|ultimate kitchen)\b.*\b(package|pkg)\b|\bultimate kitchen\b/
    # And one refrigerator: upgrades that each replace the same standard
    # fridge ("... Refer IPO 18.2", "... French Door Ref IPO 18.2CF").
    FRIDGE_SWAP = /\b(refer|ref|refrigerator|frenchdoorref|frenchdrref)\b.*\bipo\s+([0-9.]+)/

    # The family key, or nil when the name has no fuel or package axis.
    def key(name)
      text = name.to_s.downcase.gsub(/\(.*?\)/, ' ')
      return 'appliance package' if text.match?(APPLIANCE_PACKAGE) && !text.match?(/discount|omit/)
      if (m = text.match(FRIDGE_SWAP))
        return "refrigerator in place of #{m[2].sub(/\.?0+\z/, '')}"
      end

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
