# frozen_string_literal: true

module Truebuild
  # Trims the priced catalog to what a buyer should see on the dealer's site.
  # The dealer's purchase order needs every option (shirt racks, hinge
  # counts, conduit); a buyer choosing a home does not, and a thousand
  # checkboxes lose them. Hidden options are still offered: a rep adds them
  # at quote time.
  #
  #   curated     every finish and color, the floor plan and package groups,
  #               the pick-one choices buyers care about, and the dealer's
  #               popular upgrades (the default)
  #   everything  the full list
  #   custom      everything but the groups and options the dealer hides
  module BuyerView
    module_function

    MODES = %w[curated everything custom].freeze
    WHOLE_GROUPS = /floor plan|package/i
    FAMILIES = ['appliance package', 'fireplace', 'carpet upgrade', 'cabinet finish', 'exterior elevation', 'siding line'].freeze

    def apply(groups, terms)
      mode = MODES.include?(terms&.buyer_view) ? terms.buyer_view : 'curated'
      return groups if mode == 'everything'

      kept = groups.map do |g|
        options = mode == 'custom' ? custom(g, terms) : curated(g, terms)
        next nil if mode == 'custom' && hidden_group?(g, terms)

        g.merge(options: options)
      end
      kept.compact.reject { |g| g[:color_sets].empty? && g[:options].empty? }
    end

    def curated(group, terms)
      return group[:options] if group[:name].to_s.match?(WHOLE_GROUPS)

      featured = Array(terms&.buyer_featured_option_ids).map(&:to_i)
      group[:options].select { |o| featured.include?(o[:id]) || buyer_family?(o[:family]) }
    end

    def custom(group, terms)
      hidden = Array(terms&.buyer_hidden_option_ids).map(&:to_i)
      group[:options].reject { |o| hidden.include?(o[:id]) }
    end

    def hidden_group?(group, terms)
      Array(terms&.buyer_hidden_groups).map { |n| n.to_s.downcase }.include?(group[:name].to_s.downcase)
    end

    def buyer_family?(family)
      family.present? && (FAMILIES.include?(family) || family.start_with?('refrigerator'))
    end
  end
end
