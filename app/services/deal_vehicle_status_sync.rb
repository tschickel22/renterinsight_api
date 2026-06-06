# frozen_string_literal: true

# Syncs a vehicle's status with its deal's lifecycle.
#
# Two paths:
#   1. Deal transitions INTO closed_won → mark linked vehicle 'sold',
#      stamp sold_at + sold_via_deal_id.
#   2. Deal transitions OUT of closed_won (won → lost, won → reopened) →
#      if the vehicle's sold_via_deal_id points back at this deal, revert
#      it to 'available' and clear the sold metadata.
#
# Safety: if a vehicle is already 'sold' via a different deal, we DO NOT
# overwrite — this would silently re-attribute the sale. Log + skip.
# (Two deals can legitimately share a vehicle reference during draft work;
# only the deal that "claimed" it owns the revert.)
class DealVehicleStatusSync
  def self.call(deal, previous_stage:)
    new(deal, previous_stage: previous_stage).call
  end

  def initialize(deal, previous_stage:)
    @deal = deal
    @previous_stage = previous_stage&.to_s
    @new_stage = deal.stage.to_s
  end

  def call
    return unless @deal.vehicle_id.present?

    if transitioned_into_won?
      self.class.mark_sold(@deal, @deal.vehicle)
    elsif transitioned_out_of_won?
      self.class.release(@deal, @deal.vehicle)
    end
  end

  # Mark a vehicle sold on behalf of a deal, OUTSIDE the stage-transition flow (the unit-swap
  # apply path calls this directly). Same safety as the transition path: never re-attribute a
  # vehicle already sold via a DIFFERENT deal — log + skip. Idempotent for this deal.
  def self.mark_sold(deal, vehicle)
    return unless deal && vehicle

    if vehicle.status == 'sold' && vehicle.sold_via_deal_id.present? && vehicle.sold_via_deal_id != deal.id
      Rails.logger.warn(
        "[DealVehicleStatusSync] Deal #{deal.id} mark_sold but vehicle #{vehicle.id} already sold via deal #{vehicle.sold_via_deal_id} — skipping"
      )
      return false
    end

    unless vehicle.update(status: 'sold', sold_at: Time.current, sold_via_deal_id: deal.id)
      Rails.logger.error("[DealVehicleStatusSync] mark_sold validation failed for deal #{deal.id}: #{vehicle.errors.full_messages.join(', ')}")
      return false
    end
    true
  rescue => e
    Rails.logger.error("[DealVehicleStatusSync] mark_sold failed for deal #{deal.id}: #{e.message}")
    false
  end

  # Release a vehicle back to available on behalf of a deal, OUTSIDE the stage-transition flow
  # (the unit-swap apply/revert path calls this when dropping the old/swapped-in unit). The
  # ownership guard is preserved: only release when THIS deal owns the sale (sold_via_deal_id
  # == deal.id), so we never free a unit another deal claimed.
  def self.release(deal, vehicle)
    return unless deal && vehicle
    return false unless vehicle.sold_via_deal_id == deal.id

    unless vehicle.update(status: 'available', sold_at: nil, sold_via_deal_id: nil)
      Rails.logger.error("[DealVehicleStatusSync] release validation failed for deal #{deal.id}: #{vehicle.errors.full_messages.join(', ')}")
      return false
    end
    true
  rescue => e
    Rails.logger.error("[DealVehicleStatusSync] release failed for deal #{deal.id}: #{e.message}")
    false
  end

  private

  def transitioned_into_won?
    @new_stage == 'closed_won' && @previous_stage != 'closed_won'
  end

  def transitioned_out_of_won?
    @previous_stage == 'closed_won' && @new_stage != 'closed_won'
  end
end
