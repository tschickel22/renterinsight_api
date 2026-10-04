# frozen_string_literal: true

module Truebuild
  # Which factories a dealer's buyers see in TrueBuild (backlog E64): the
  # ones a platform admin gave the dealer, while they stay released. Before
  # this, every dealer with pricing saw every factory with a published book,
  # which at a hundred factories puts Topeka's homes on a Georgia dealer's site.
  module DealerFactories
    module_function

    SUGGEST_MILES = 250

    def offered_ids(company)
      company.dealer_factories.joins(:factory).merge(Factory.truebuild_released).pluck(:factory_id).to_set
    end

    # A plan with no factory (a book that prices a manufacturer's homes
    # without naming the plant) is offered when the dealer has any released
    # factory of that manufacturer.
    # Checking many models: pass ids and manufacturers once (see ModelList).
    def offered?(company, variant, ids = offered_ids(company), manufacturers = nil)
      return false unless variant

      factory_id = variant.catalog_plan&.factory_id
      return ids.include?(factory_id) if factory_id

      (manufacturers || offered_manufacturer_ids(ids)).include?(variant.manufacturer_id)
    end

    # The offered ones among these model ids, in one query.
    def offered_variant_ids(company, variant_ids)
      ids = offered_ids(company)
      return [] if ids.empty? || variant_ids.empty?

      CatalogPlanVariant.joins(:catalog_plan).where(id: variant_ids)
                        .where('catalog_plans.factory_id IN (:f) OR (catalog_plans.factory_id IS NULL AND ' \
                               'catalog_plan_variants.manufacturer_id IN (:m))', f: ids.to_a, m: offered_manufacturer_ids(ids).to_a)
                        .pluck(:id)
    end

    def offered_manufacturer_ids(ids)
      Factory.where(id: ids.to_a).distinct.pluck(:manufacturer_id).to_set
    end

    # Released factories the dealer does not have yet, within SUGGEST_MILES of
    # any of their locations, nearest first. Where a location or factory
    # cannot be placed, a factory in the same state counts as near.
    # => [{ factory:, miles: }]
    def suggestions(company)
      given = company.dealer_factories.pluck(:factory_id)
      locations = company.locations.where(is_deleted: [false, nil])
      points = locations.filter_map { |l| ZipPoint.call(l.zip_code) }
      states = locations.filter_map { |l| state(l.state) }.uniq
      Factory.truebuild_released.where.not(id: given).includes(:manufacturer).filter_map do |f|
        point = f.latitude && f.longitude ? [f.latitude, f.longitude] : ZipPoint.call(f.zip)
        miles = (points.map { |p| ZipPoint.miles(p, point) }.min if point && points.any?)
        near = miles ? miles <= SUGGEST_MILES : states.include?(state(f.state))
        { factory: f, miles: miles&.round } if near
      end.sort_by { |s| [s[:miles] || Float::INFINITY, s[:factory].name] }
    end

    def state(value)
      v = value.to_s.strip.upcase
      v.length == 2 ? v : STATES[v]
    end

    STATES = { 'ALABAMA' => 'AL', 'ALASKA' => 'AK', 'ARIZONA' => 'AZ', 'ARKANSAS' => 'AR', 'CALIFORNIA' => 'CA',
               'COLORADO' => 'CO', 'CONNECTICUT' => 'CT', 'DELAWARE' => 'DE', 'FLORIDA' => 'FL', 'GEORGIA' => 'GA',
               'HAWAII' => 'HI', 'IDAHO' => 'ID', 'ILLINOIS' => 'IL', 'INDIANA' => 'IN', 'IOWA' => 'IA', 'KANSAS' => 'KS',
               'KENTUCKY' => 'KY', 'LOUISIANA' => 'LA', 'MAINE' => 'ME', 'MARYLAND' => 'MD', 'MASSACHUSETTS' => 'MA',
               'MICHIGAN' => 'MI', 'MINNESOTA' => 'MN', 'MISSISSIPPI' => 'MS', 'MISSOURI' => 'MO', 'MONTANA' => 'MT',
               'NEBRASKA' => 'NE', 'NEVADA' => 'NV', 'NEW HAMPSHIRE' => 'NH', 'NEW JERSEY' => 'NJ', 'NEW MEXICO' => 'NM',
               'NEW YORK' => 'NY', 'NORTH CAROLINA' => 'NC', 'NORTH DAKOTA' => 'ND', 'OHIO' => 'OH', 'OKLAHOMA' => 'OK',
               'OREGON' => 'OR', 'PENNSYLVANIA' => 'PA', 'RHODE ISLAND' => 'RI', 'SOUTH CAROLINA' => 'SC',
               'SOUTH DAKOTA' => 'SD', 'TENNESSEE' => 'TN', 'TEXAS' => 'TX', 'UTAH' => 'UT', 'VERMONT' => 'VT',
               'VIRGINIA' => 'VA', 'WASHINGTON' => 'WA', 'WEST VIRGINIA' => 'WV', 'WISCONSIN' => 'WI', 'WYOMING' => 'WY' }.freeze
  end
end
