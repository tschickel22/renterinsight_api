# frozen_string_literal: true

class AddCommissionEconomicsToDeals < ActiveRecord::Migration[8.0]
  def change
    # Economics fields for commission calculations
    add_column :deals, :selling_price, :decimal, precision: 15, scale: 2
    add_column :deals, :unit_cost, :decimal, precision: 15, scale: 2
    add_column :deals, :trade_allowance, :decimal, precision: 15, scale: 2, default: 0
    add_column :deals, :trade_payoff, :decimal, precision: 15, scale: 2, default: 0
    add_column :deals, :pack_amount, :decimal, precision: 15, scale: 2
    add_column :deals, :finance_reserve, :decimal, precision: 15, scale: 2, default: 0
    add_column :deals, :product_margin, :decimal, precision: 15, scale: 2, default: 0
    add_column :deals, :accessories_total, :decimal, precision: 15, scale: 2, default: 0
    add_column :deals, :doc_fee, :decimal, precision: 15, scale: 2, default: 0
    
    # MH-specific fees
    add_column :deals, :delivery_fee, :decimal, precision: 15, scale: 2, default: 0
    add_column :deals, :setup_fee, :decimal, precision: 15, scale: 2, default: 0
    add_column :deals, :skirting_fee, :decimal, precision: 15, scale: 2, default: 0
    
    # Deal lifecycle and type
    add_column :deals, :deal_type, :string # "new", "used"
    add_column :deals, :vertical, :string # "rv", "mh"
    add_column :deals, :quantity, :integer, default: 1
    add_column :deals, :delivery_date, :date
    add_column :deals, :primary_salesperson_id, :bigint
    
    # Indexes for commission queries
    add_index :deals, [:company_id, :delivery_date], name: 'index_deals_on_company_and_delivery'
    add_index :deals, [:primary_salesperson_id, :delivery_date], name: 'index_deals_on_salesperson_and_delivery'
    add_index :deals, [:deal_type], name: 'index_deals_on_deal_type'
    add_index :deals, [:vertical], name: 'index_deals_on_vertical'
    
    # Foreign key for primary salesperson
    add_foreign_key :deals, :users, column: :primary_salesperson_id
  end
end
