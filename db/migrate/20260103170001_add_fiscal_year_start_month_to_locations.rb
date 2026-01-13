# frozen_string_literal: true

class AddFiscalYearStartMonthToLocations < ActiveRecord::Migration[7.0]
  def change
    add_column :locations, :fiscal_year_start_month, :integer, default: nil, null: true
    
    # Add comment explaining the column
    reversible do |dir|
      dir.up do
        execute <<-SQL
          COMMENT ON COLUMN locations.fiscal_year_start_month IS 
          'Month when fiscal year starts (1=January, 2=February, etc.). Used for quarterly commission calculations. If NULL, falls back to company.fiscal_year_start_month. If both NULL, defaults to 1 (January) for calendar year.';
        SQL
      end
    end
  end
end
