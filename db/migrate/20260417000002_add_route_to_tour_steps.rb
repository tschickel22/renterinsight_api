# frozen_string_literal: true

# Lets a tour step opt out of the tour's default landing page and direct the
# overlay to a different route mid-tour (e.g. step 1 lives on the index, step 2
# requires the form to be open). Steps without a route fall back to the tour's
# module.route on the frontend.
class AddRouteToTourSteps < ActiveRecord::Migration[8.0]
  def change
    add_column :tour_steps, :route, :string
  end
end
