# frozen_string_literal: true

# Picks vehicles to recommend to an entity (Lead/Contact) via a 4-step waterfall:
#   1. preferred_home    — explicit interested home on the record
#   2. click_inferred    — top clicked vehicles from this entity's tracked links
#   3. criteria_match    — preference fields (beds/baths/sqft/type/budget)
#   4. rotation          — newest available inventory as a generic fallback
class InventoryMatcherService
  MAX_RESULTS = 3
  DEFAULT_STATUSES = %w[available available_to_order].freeze
  ALLOWED_STATUSES = %w[available available_to_order pending reserved].freeze

  # `filters` is a small hash with optional overrides:
  #   :statuses         — array of vehicle status strings to include
  #   :require_images   — bool; when true, drop rows with empty images
  # Empty / nil → today's default behavior (available + available_to_order,
  # no image gate on the primary match paths).
  def initialize(entity, company, filters: {})
    @entity  = entity
    @company = company
    @filters = filters || {}
  end

  def match
    result = match_preferred_home
    return result if result.present?
    result = match_click_inferred
    return result if result.present?
    result = match_criteria
    return result if result.present?
    match_rotation
  end

  def match_mode
    return 'preferred_home' if match_preferred_home.present?
    return 'click_inferred' if match_click_inferred.present?
    return 'criteria_match' if match_criteria.present?
    return 'rotation'       if match_rotation.present?
    'none'
  end

  private

  def available_inventory
    @available_inventory ||= begin
      base = @company.vehicles
                     .where(status: filter_statuses)
                     .where(is_deleted: [false, nil])
      require_images? ? with_images_only(base) : base
    end
  end

  def filter_statuses
    picked = Array(@filters[:statuses] || @filters['statuses']).map(&:to_s)
                                                              .select { |s| ALLOWED_STATUSES.include?(s) }
    picked.presence || DEFAULT_STATUSES
  end

  def require_images?
    ActiveModel::Type::Boolean.new.cast(@filters[:require_images] || @filters['require_images'] || false)
  end

  # Same jsonb pre-filter Messaging::InventoryBlockResolver uses so campaigns
  # and nurture agree on "has at least one image".
  def with_images_only(rel)
    rel.where("images IS NOT NULL AND images::text NOT IN ('[]', '')")
  end

  def match_preferred_home
    vid = @entity.is_a?(Lead) ? @entity.vehicle_id : @entity.try(:preferred_vehicle_id)
    return nil unless vid
    vehicle = available_inventory.find_by(id: vid)
    vehicle ? [vehicle] : nil
  end

  def match_click_inferred
    top = TrackedLink
      .where(entity_type: @entity.class.name, entity_id: @entity.id)
      .where.not(vehicle_id: nil)
      .where('click_count > 0')
      .group(:vehicle_id)
      .order(Arel.sql('SUM(click_count) DESC'))
      .limit(MAX_RESULTS)
      .pluck(:vehicle_id)
    return nil if top.empty?
    vehicles = available_inventory.where(id: top)
    vehicles.present? ? vehicles.to_a : nil
  end

  def match_criteria
    scope = available_inventory

    budget = @entity.try(:budget_range)
    if budget.present?
      range = parse_budget_range(budget)
      if range
        scope = scope.where('sale_price >= ?', range[:min]) if range[:min]
        scope = scope.where('sale_price <= ?', range[:max]) if range[:max]
      end
    end

    beds = @entity.try(:preferred_bedrooms)
    scope = scope.where(bedrooms: beds) if beds.present? && beds.to_i > 0

    baths = @entity.try(:preferred_bathrooms)
    scope = scope.where(bathrooms: baths) if baths.present? && baths.to_i > 0

    min_sqft = @entity.try(:preferred_min_sqft)
    scope = scope.where('square_feet >= ?', min_sqft) if min_sqft.present? && min_sqft.to_i > 0

    max_sqft = @entity.try(:preferred_max_sqft)
    scope = scope.where('square_feet <= ?', max_sqft) if max_sqft.present? && max_sqft.to_i > 0

    home_type = @entity.try(:preferred_home_type)
    scope = scope.where(listing_type: home_type) if home_type.present?

    results = scope.order(created_at: :desc).limit(MAX_RESULTS).to_a
    results.present? ? results : nil
  end

  def match_rotation
    with_images = available_inventory
      .where("images IS NOT NULL AND images::text != '[]' AND images::text != ''")
      .order(created_at: :desc)
      .limit(MAX_RESULTS)
      .to_a

    return with_images if with_images.present?
    available_inventory.order(created_at: :desc).limit(MAX_RESULTS).to_a
  end

  def parse_budget_range(range_string)
    return nil if range_string.blank?

    normalized = range_string.gsub(/[\$,]/, '').downcase
    normalized = normalized.gsub(/(\d+)k/) { (Regexp.last_match(1).to_i * 1000).to_s }

    if normalized.include?('-')
      parts = normalized.split('-').map { |p| p.gsub(/[^\d.]/, '').to_f }
      { min: parts[0], max: parts[1] }
    elsif normalized.match?(/under|below/)
      { min: nil, max: normalized.gsub(/[^\d.]/, '').to_f }
    elsif normalized.match?(/\+|over|above/)
      { min: normalized.gsub(/[^\d.]/, '').to_f, max: nil }
    else
      val = normalized.gsub(/[^\d.]/, '').to_f
      { min: val * 0.8, max: val * 1.2 }
    end
  end
end
