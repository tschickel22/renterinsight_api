# frozen_string_literal: true

# Nightly job. Emits `vehicle.days_on_lot_exceeded` workflow events the first
# time a vehicle crosses the 60-day threshold. Uses a per-vehicle marker in
# Rails cache so the event fires once per crossing, not every night.
class VehicleDaysOnLotCheckJob < ApplicationJob
  queue_as :low

  THRESHOLD_DAYS = 60

  def perform
    cutoff = THRESHOLD_DAYS.days.ago

    scope = Vehicle.where(is_deleted: false, status: 'available')
                   .where('COALESCE(date_in_stock, created_at) <= ?', cutoff)

    emitted = 0
    scope.find_each do |vehicle|
      key = "days_on_lot_emitted:#{vehicle.id}"
      next if Rails.cache.read(key)

      WorkflowEngine.emit('vehicle.days_on_lot_exceeded', vehicle, {
        id:            vehicle.id,
        days_on_lot:   ((Time.current - (vehicle.date_in_stock || vehicle.created_at)) / 1.day).to_i,
        threshold:     THRESHOLD_DAYS
      })

      Rails.cache.write(key, Time.current, expires_in: 90.days)
      emitted += 1
    end

    Rails.logger.info "[VehicleDaysOnLotCheckJob] emitted=#{emitted}"
  end
end
