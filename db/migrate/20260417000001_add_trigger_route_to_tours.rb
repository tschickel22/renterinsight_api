# frozen_string_literal: true

# trigger_route lets a tour announce "auto-fire me when the user lands on
# /this-route" — the frontend tour bootstrapper reads it and decides whether
# to start the tour automatically (gated by user_tour_completions).
class AddTriggerRouteToTours < ActiveRecord::Migration[8.0]
  def change
    add_column :tours, :trigger_route, :string
    add_index  :tours, :trigger_route
  end
end
