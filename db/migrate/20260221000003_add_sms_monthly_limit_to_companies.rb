class AddSmsMonthlyLimitToCompanies < ActiveRecord::Migration[8.0]
  def change
    # Only add if column does not already exist
    unless column_exists?(:companies, :sms_monthly_limit)
      add_column :companies, :sms_monthly_limit, :integer, default: 2000, null: false
    end
  end
end
