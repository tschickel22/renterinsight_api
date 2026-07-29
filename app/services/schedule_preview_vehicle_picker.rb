# frozen_string_literal: true

# Picks a vehicle to feature for a given intent_category. Used both by the
# scheduled-post job and the schedule preview endpoint.
class SchedulePreviewVehiclePicker
  NO_VEHICLE_INTENTS = %w[social_proof education lifestyle seasonal financing].freeze
  DEFAULT_STATUSES = %w[available].freeze

  # statuses:       which inventory statuses are eligible. Defaults to
  #                 'available' only, matching the original behavior.
  # require_photos: skip units with no photo_url and no images.
  def self.pick(company:, intent:, statuses: nil, require_photos: false)
    # Only inventory-centric (dealer) industries feature a specific vehicle/unit.
    # SaaS / generic industries never attach a vehicle.
    return nil unless SocialPostIntentCatalog.for_company(company).family == :dealer
    return nil if NO_VEHICLE_INTENTS.include?(intent.to_s)

    eligible = Array(statuses).map(&:to_s).select { |s| Vehicle::STATUSES.include?(s) }.presence || DEFAULT_STATUSES
    scope = company.vehicles.where(is_deleted: false, status: eligible)
    scope = scope.with_images if require_photos

    case intent.to_s
    when 'aged_inventory'
      scope.order(Arel.sql('COALESCE(date_in_stock, created_at) ASC')).first
    when 'new_arrival'
      scope.order(Arel.sql('COALESCE(date_in_stock, created_at) DESC')).first
    when 'specific_unit', 'price_drop', 'ad_content'
      recent_ids = company.social_posts
                          .where('created_at >= ?', 7.days.ago)
                          .where.not(vehicle_id: nil)
                          .pluck(:vehicle_id)
      candidates = scope.where.not(id: recent_ids)
      candidates = scope if candidates.count.zero?
      candidates.order(Arel.sql('RANDOM()')).first
    else
      scope.order(Arel.sql('RANDOM()')).first
    end
  end

  # Convenience wrapper so callers holding a schedule don't have to unpack its
  # inventory options by hand.
  def self.pick_for(schedule, intent:)
    pick(
      company:        schedule.company,
      intent:         intent,
      statuses:       schedule.selectable_inventory_statuses,
      require_photos: schedule.require_photos
    )
  end
end
