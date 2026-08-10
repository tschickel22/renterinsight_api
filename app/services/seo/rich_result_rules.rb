# frozen_string_literal: true

module Seo
  # Whether structured data is actually eligible for a rich result, rather than
  # merely present.
  #
  # Our audit used to ask "is there a Product node?" and stop. A listing with a
  # Product carrying no offer passed that check and was reported as good markup,
  # while Google's own Rich Results Test called the same page ineligible. We
  # measured exactly that on a live site: a Product with no price, reported by us
  # as present and by Google as nothing at all.
  #
  # There is no API for the Rich Results Test, so this encodes the documented
  # requirements instead. It is deliberately conservative: only properties Google
  # documents as required are treated as blocking, because a check that fires on
  # something every competent site omits is the finding a prospect checks
  # personally, and it decides whether they believe the rest of the report.
  #
  # Used two ways. On a prospect's site it produces findings. On our own rendered
  # output it is a regression test, which is the half that has to hold: a gap on
  # their site is a reason to call, and the same gap on ours is a defect.
  module RichResultRules
    # severity: :required blocks the rich result outright. :recommended costs
    # detail in the result but still shows.
    #
    # source: :markup is ours to emit. :data depends on what the dealer entered,
    # and reporting it as our bug would fill an internal report with noise
    # nobody can action.
    Issue = Struct.new(:type, :property, :severity, :source, :consequence, keyword_init: true) do
      def required?
        severity == :required
      end

      def to_h
        { 'type' => type, 'property' => property, 'severity' => severity.to_s,
          'source' => source.to_s, 'consequence' => consequence }
      end
    end

    RULES = {
      'Product' => [
        { property: 'name', severity: :required, source: :markup,
          consequence: 'the listing cannot appear as a product result at all' },
        { property: 'image', severity: :required, source: :data,
          consequence: 'a listing with no photograph is not eligible for a product result' },
        { property: 'offers', severity: :required, source: :data,
          consequence: 'price and availability never reach a search result' },
        { property: 'offers.price', severity: :required, source: :data,
          consequence: 'the result shows no price, which is what buyers scan for' },
        { property: 'offers.priceCurrency', severity: :required, source: :markup,
          consequence: 'a price with no currency is discarded' },
        { property: 'offers.availability', severity: :recommended, source: :markup,
          consequence: 'the result cannot say whether the home is still available' },
        { property: 'brand', severity: :recommended, source: :data,
          consequence: 'the manufacturer is not shown alongside the home' }
      ],
      'LocalBusiness' => [
        { property: 'name', severity: :required, source: :markup,
          consequence: 'nothing identifies the dealership' },
        { property: 'address', severity: :required, source: :data,
          consequence: 'the dealership cannot appear in map or local results' },
        { property: 'address.postalCode', severity: :required, source: :data,
          consequence: 'the address cannot be matched to the Business Profile' },
        { property: 'telephone', severity: :recommended, source: :data,
          consequence: 'a local result with no phone number loses its call button' },
        { property: 'image', severity: :recommended, source: :data,
          consequence: 'the listing shows without a picture' },
        { property: 'priceRange', severity: :recommended, source: :data,
          consequence: 'buyers cannot tell the price bracket before clicking' },
        { property: 'openingHoursSpecification', severity: :recommended, source: :data,
          consequence: 'the result cannot show whether the lot is open now' }
      ],
      'BreadcrumbList' => [
        { property: 'itemListElement', severity: :required, source: :markup,
          consequence: 'results show a raw URL instead of a readable trail' }
      ],
      'ItemList' => [
        { property: 'itemListElement', severity: :required, source: :markup,
          consequence: 'the list cannot be read as a set of homes' }
      ]
    }.freeze

    # Types that stand in for LocalBusiness. Checking only the literal type would
    # miss every dealer we mark up correctly, since the business type follows the
    # dealer's industry.
    LOCAL_BUSINESS_TYPES = %w[LocalBusiness AutoDealer RealEstateAgent SelfStorage
                              HomeGoodsStore Store].freeze

    module_function

    # @param nodes [Array<Hash>] every schema.org node on a page, @graph flattened
    # @return [Array<Issue>]
    def issues_for(nodes)
      Array(nodes).flat_map { |node| node_issues(node) }.compact
    end

    def node_issues(node)
      return [] unless node.is_a?(Hash)

      rule_key = rule_key_for(node)
      return [] if rule_key.nil?

      RULES.fetch(rule_key, []).filter_map do |rule|
        next if present?(node, rule[:property])
        # When the parent is absent the children are absent by construction, and
        # saying so four times over is noise. Worse, it misattributes: a home
        # with no price gets no offer node at all, and reporting the currency we
        # never got to emit as our failure would log a dealer's blank field as
        # our defect.
        next if parent_missing?(node, rule[:property])

        Issue.new(type: rule_key, property: rule[:property], severity: rule[:severity],
                  source: rule[:source], consequence: rule[:consequence])
      end
    end

    def parent_missing?(node, path)
      parent = path.to_s.rpartition('.').first
      parent.present? && !present?(node, parent)
    end

    def rule_key_for(node)
      types = Array(node['@type']).map(&:to_s)
      return 'LocalBusiness' if types.any? { |t| LOCAL_BUSINESS_TYPES.include?(t) }

      types.find { |t| RULES.key?(t) }
    end

    # Walks a dotted path so a rule can name offers.price rather than needing its
    # own branch. An array is satisfied when any entry has the property, since a
    # page may legitimately carry several offers.
    def present?(node, path)
      value = path.to_s.split('.').reduce(node) do |current, key|
        return false if current.nil?

        case current
        when Hash then current[key]
        when Array then current.filter_map { |entry| entry.is_a?(Hash) ? entry[key] : nil }.first
        end
      end

      case value
      when nil then false
      when String then value.strip.present?
      when Array, Hash then value.present?
      else true
      end
    end

    # Flattens whatever a page's JSON-LD is shaped like. @graph is how most CMSs
    # nest their types, and reading only the top level reports a well-marked-up
    # site as having nothing.
    def nodes_from(parsed)
      Array.wrap(parsed).flat_map do |item|
        next [] unless item.is_a?(Hash)

        graph = Array.wrap(item['@graph']).select { |n| n.is_a?(Hash) }
        graph.any? ? graph : [item]
      end
    end
  end
end
