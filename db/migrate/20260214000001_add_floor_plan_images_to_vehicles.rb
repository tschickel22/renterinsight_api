# frozen_string_literal: true

class AddFloorPlanImagesToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :floor_plan_images, :json, default: [], null: false
  end
end
