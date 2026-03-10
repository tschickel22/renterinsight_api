class AddStateTaxRatesToCompanies < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:companies, :state_tax_rates)
      add_column :companies, :state_tax_rates, :jsonb, default: {}, null: false
    end
  end
end
