# frozen_string_literal: true

class AddSalesTaxConfigToAccountingSettings < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:accounting_settings, :sales_tax_enabled)
      add_column :accounting_settings, :sales_tax_enabled, :boolean, default: false, null: false
    end

    unless column_exists?(:accounting_settings, :default_state_tax_rate)
      add_column :accounting_settings, :default_state_tax_rate, :decimal, precision: 8, scale: 5
    end

    unless column_exists?(:accounting_settings, :default_county_tax_rate)
      add_column :accounting_settings, :default_county_tax_rate, :decimal, precision: 8, scale: 5
    end

    unless column_exists?(:accounting_settings, :default_city_tax_rate)
      add_column :accounting_settings, :default_city_tax_rate, :decimal, precision: 8, scale: 5
    end

    unless column_exists?(:accounting_settings, :state_tax_account_id)
      add_reference :accounting_settings, :state_tax_account, type: :bigint, null: true, index: true,
                    foreign_key: { to_table: :chart_of_accounts }
    end

    unless column_exists?(:accounting_settings, :county_tax_account_id)
      add_reference :accounting_settings, :county_tax_account, type: :bigint, null: true, index: true,
                    foreign_key: { to_table: :chart_of_accounts }
    end

    unless column_exists?(:accounting_settings, :city_tax_account_id)
      add_reference :accounting_settings, :city_tax_account, type: :bigint, null: true, index: true,
                    foreign_key: { to_table: :chart_of_accounts }
    end

    unless column_exists?(:accounting_settings, :tax_rates_by_state)
      add_column :accounting_settings, :tax_rates_by_state, :jsonb, default: {}, null: false
    end
  end
end
