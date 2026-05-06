# frozen_string_literal: true

# pack_amount already exists on the deals table — do not re-add.
class AddAccountingFieldsToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :home_cost, :decimal, precision: 15, scale: 2
    add_column :deals, :reconditioning_cost, :decimal, precision: 15, scale: 2
    add_column :deals, :floor_plan_interest, :decimal, precision: 15, scale: 2
    add_column :deals, :delivery_setup_cost, :decimal, precision: 15, scale: 2
    add_column :deals, :front_gross, :decimal, precision: 15, scale: 2

    add_column :deals, :back_gross, :decimal, precision: 15, scale: 2
    add_column :deals, :total_gross, :decimal, precision: 15, scale: 2

    add_column :deals, :commission_amount, :decimal, precision: 15, scale: 2
    add_column :deals, :net_deal_profit, :decimal, precision: 15, scale: 2

    add_column :deals, :gl_posted, :boolean, default: false
    add_column :deals, :gl_posted_at, :datetime
    add_column :deals, :gl_journal_entry_id, :bigint

    add_index :deals, :gl_posted
    add_index :deals, :gl_journal_entry_id
  end
end
