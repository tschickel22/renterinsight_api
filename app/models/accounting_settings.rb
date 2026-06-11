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

  # Tax-payable GL accounts, by jurisdiction. When an account hasn't been explicitly
  # chosen, fall back to the standard seeded Sales Tax Payable accounts by number
  # (2210 State / 2220 County / 2230 City) so sales tax still posts out of the box.
  # The user can override any of these in Accounting Settings → Sales Tax.
  DEFAULT_TAX_ACCOUNT_NUMBERS = { state: '2210', county: '2220', city: '2230' }.freeze

  def tax_accounts
    {
      state:  state_tax_account  || default_tax_account(:state),
      county: county_tax_account || default_tax_account(:county),
      city:   city_tax_account   || default_tax_account(:city)
    }
  end

  # The resolved (effective) account for a jurisdiction — explicit choice or the seeded
  # default. Used by the API so the UI can show what will actually be used.
  def effective_tax_account(jurisdiction)
    tax_accounts[jurisdiction.to_sym]
  end

  # True when the jurisdiction is using the seeded default (not an explicit override).
  def tax_account_is_default?(jurisdiction)
    explicit = public_send("#{jurisdiction}_tax_account")
    explicit.nil? && default_tax_account(jurisdiction).present?
  end

  private

  # Look up the seeded default tax-payable account for a jurisdiction by number.
  def default_tax_account(jurisdiction)
    number = DEFAULT_TAX_ACCOUNT_NUMBERS[jurisdiction.to_sym]
    return nil unless number
    company&.chart_of_accounts&.find_by(account_number: number)
  end

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
