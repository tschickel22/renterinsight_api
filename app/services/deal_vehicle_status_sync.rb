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
      mark_sold
    elsif transitioned_out_of_won?
      revert_if_owned
    end
  end

  private

  def transitioned_into_won?
    @new_stage == 'closed_won' && @previous_stage != 'closed_won'
  end

  def transitioned_out_of_won?
    @previous_stage == 'closed_won' && @new_stage != 'closed_won'
  end

  def mark_sold
    vehicle = @deal.vehicle
    return unless vehicle

    if vehicle.status == 'sold' && vehicle.sold_via_deal_id.present? && vehicle.sold_via_deal_id != @deal.id
      Rails.logger.warn(
        "[DealVehicleStatusSync] Deal #{@deal.id} closed_won but vehicle #{vehicle.id} already sold via deal #{vehicle.sold_via_deal_id} — skipping"
      )
      return
    end

    unless vehicle.update(status: 'sold', sold_at: Time.current, sold_via_deal_id: @deal.id)
      Rails.logger.error("[DealVehicleStatusSync] mark_sold validation failed for deal #{@deal.id}: #{vehicle.errors.full_messages.join(', ')}")
    end
  rescue => e
    Rails.logger.error("[DealVehicleStatusSync] mark_sold failed for deal #{@deal.id}: #{e.message}")
  end

  def revert_if_owned
    vehicle = @deal.vehicle
    return unless vehicle
    return unless vehicle.sold_via_deal_id == @deal.id

    unless vehicle.update(status: 'available', sold_at: nil, sold_via_deal_id: nil)
      Rails.logger.error("[DealVehicleStatusSync] revert validation failed for deal #{@deal.id}: #{vehicle.errors.full_messages.join(', ')}")
    end
  rescue => e
    Rails.logger.error("[DealVehicleStatusSync] revert failed for deal #{@deal.id}: #{e.message}")
  end
end
