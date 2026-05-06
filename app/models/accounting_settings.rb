# frozen_string_literal: true

class AccountingSettings < ApplicationRecord
  belongs_to :company
  belongs_to :retained_earnings_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :default_ar_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :default_ap_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :default_sales_revenue_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :default_cogs_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :default_sales_tax_payable_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :default_bank_account, class_name: 'BankAccount', optional: true

  validates :company_id, uniqueness: true
  validates :fiscal_year_start_month, inclusion: { in: 1..12 }

  def self.for_company(company)
    find_or_create_by!(company: company)
  end
end
