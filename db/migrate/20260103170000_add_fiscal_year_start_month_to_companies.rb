# frozen_string_literal: true

class AddFiscalYearStartMonthToCompanies < ActiveRecord::Migration[7.0]
  def change
    add_column :companies, :fiscal_year_start_month, :integer, default: 1, null: false
    
    # Add comment explaining the column
    reversible do |dir|
      dir.up do
        execute <<-SQL
          COMMENT ON COLUMN companies.fiscal_year_start_month IS 
          'Month when fiscal year starts (1=January, 2=February, etc.). Used for quarterly commission calculations. Default is 1 (January) for calendar year.';
        SQL
      end
    end
  end
end
