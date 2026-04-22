# frozen_string_literal: true

# Picks a vehicle to feature for a given intent_category. Used both by the
# scheduled-post job and the schedule preview endpoint.
class SchedulePreviewVehiclePicker
  NO_VEHICLE_INTENTS = %w[social_proof education lifestyle seasonal financing].freeze

  def self.pick(company:, intent:)
    return nil if NO_VEHICLE_INTENTS.include?(intent.to_s)
    scope = company.vehicles.where(is_deleted: false, status: 'available')

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
end
