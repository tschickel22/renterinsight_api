# frozen_string_literal: true

# Tracks how/when a vehicle was sold so DealVehicleStatusSync can safely
# revert the status if the original closing deal moves back out of
# closed_won. Without sold_via_deal_id we couldn't tell "sold by this deal"
# apart from "sold separately" — the revert would either be unsafe or
# never fire.
class AddSoldTrackingToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :sold_at,          :datetime
    add_column :vehicles, :sold_via_deal_id, :bigint

    add_index :vehicles, :sold_via_deal_id
  end
end
