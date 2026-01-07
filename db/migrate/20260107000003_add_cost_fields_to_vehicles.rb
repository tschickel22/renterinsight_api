class AddCostFieldsToVehicles < ActiveRecord::Migration[8.0]
  def change
    # Add cost-related fields to vehicles table
    add_column :vehicles, :dealer_cost, :decimal, precision: 10, scale: 2, comment: 'Base invoice cost from manufacturer'
    add_column :vehicles, :freight_cost, :decimal, precision: 10, scale: 2, comment: 'Transportation/shipping cost to dealership'
    add_column :vehicles, :pdi_cost, :decimal, precision: 10, scale: 2, comment: 'Pre-delivery inspection and setup cost'
    add_column :vehicles, :total_cost, :decimal, precision: 10, scale: 2, comment: 'Total dealer cost (dealer_cost + freight + pdi)'
    add_column :vehicles, :holdback_amount, :decimal, precision: 10, scale: 2, comment: 'Manufacturer holdback/rebate amount'
    add_column :vehicles, :floor_plan_rate, :decimal, precision: 5, scale: 3, comment: 'Monthly floor plan interest rate (if financed)'
    add_column :vehicles, :target_gross, :decimal, precision: 10, scale: 2, comment: 'Target gross profit for this unit'
    add_column :vehicles, :minimum_price, :decimal, precision: 10, scale: 2, comment: 'Minimum acceptable selling price'
    
    # Add index for cost-based queries
    add_index :vehicles, :total_cost
    add_index :vehicles, :dealer_cost
  end
end
