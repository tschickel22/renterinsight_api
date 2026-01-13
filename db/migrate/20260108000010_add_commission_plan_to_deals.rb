# frozen_string_literal: true

class AddCommissionPlanToDeals < ActiveRecord::Migration[8.0]
  def change
    add_reference :deals, :commission_plan, foreign_key: true, index: true
    
    # Add index for querying deals by plan
    add_index :deals, [:commission_plan_id, :delivery_date], name: 'index_deals_on_plan_and_delivery'
  end
end
