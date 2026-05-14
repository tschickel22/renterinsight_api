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
  belongs_to :state_tax_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :county_tax_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :city_tax_account, class_name: 'ChartOfAccount', optional: true

  validates :company_id, uniqueness: true
  validates :fiscal_year_start_month, inclusion: { in: 1..12 }
  validates :accounting_method, inclusion: { in: %w[accrual cash] }, allow_nil: true

  # New companies should have auto-posting enabled by default
  after_initialize :set_auto_post_defaults, if: :new_record?

  def self.for_company(company)
    find_or_create_by!(company: company)
  end

  # Returns tax rate breakdown for a given state code, falling back to default rates
  # when no state-specific override is configured.
  def combined_tax_rate(state_code)
    overrides = (tax_rates_by_state || {})[state_code.to_s] || {}

    state_rate  = decimal_rate(overrides['state'],  default_state_tax_rate)
    county_rate = decimal_rate(overrides['county'], default_county_tax_rate)
    city_rate   = decimal_rate(overrides['city'],   default_city_tax_rate)

    {
      state: state_rate,
      county: county_rate,
      city: city_rate,
      combined: state_rate + county_rate + city_rate
    }
  end

  def tax_accounts
    {
      state: state_tax_account,
      county: county_tax_account,
      city: city_tax_account
    }
  end

  private

  def set_auto_post_defaults
    self.auto_post_invoices = true if auto_post_invoices.nil?
    self.auto_post_payments = true if auto_post_payments.nil?
    self.auto_post_purchases = true if auto_post_purchases.nil?
  end

  def decimal_rate(override, fallback)
    value = override.presence || fallback
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal('0')
  end
end
