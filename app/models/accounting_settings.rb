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
  belongs_to :default_parts_inventory_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :default_vehicle_inventory_account, class_name: 'ChartOfAccount', optional: true

  validates :company_id, uniqueness: true
  validates :fiscal_year_start_month, inclusion: { in: 1..12 }

  # New companies should have auto-posting enabled by default
  after_initialize :set_auto_post_defaults, if: :new_record?

  def self.for_company(company)
    find_or_create_by!(company: company)
  end

  private

  def set_auto_post_defaults
    self.auto_post_invoices = true if auto_post_invoices.nil?
    self.auto_post_payments = true if auto_post_payments.nil?
    self.auto_post_purchases = true if auto_post_purchases.nil?
  end
end
