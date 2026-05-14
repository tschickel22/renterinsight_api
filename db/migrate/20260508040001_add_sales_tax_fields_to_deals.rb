# frozen_string_literal: true

class AddSalesTaxFieldsToDeals < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:deals, :delivery_state)
      add_column :deals, :delivery_state, :string, limit: 2
    end

    unless column_exists?(:deals, :state_tax_rate)
      add_column :deals, :state_tax_rate, :decimal, precision: 8, scale: 5
    end

    unless column_exists?(:deals, :county_tax_rate)
      add_column :deals, :county_tax_rate, :decimal, precision: 8, scale: 5
    end

    unless column_exists?(:deals, :city_tax_rate)
      add_column :deals, :city_tax_rate, :decimal, precision: 8, scale: 5
    end

    unless column_exists?(:deals, :total_tax_amount)
      add_column :deals, :total_tax_amount, :decimal, precision: 15, scale: 2
    end

    unless column_exists?(:deals, :tax_posted)
      add_column :deals, :tax_posted, :boolean, default: false, null: false
    end

    unless column_exists?(:deals, :tax_journal_entry_ids)
      add_column :deals, :tax_journal_entry_ids, :jsonb, default: [], null: false
    end
  end
end
