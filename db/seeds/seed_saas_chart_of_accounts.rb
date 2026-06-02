# frozen_string_literal: true

# Idempotent seeder for a default Chart of Accounts tailored to a SaaS /
# subscription business (e.g. the Renter Insight platform tenant). Mirrors the
# structure of DefaultChartOfAccountsSeeder but swaps dealer-specific accounts
# (vehicle/home inventory, floor plan, F&I) for SaaS constructs: recurring
# subscription revenue, deferred revenue, and cost-of-revenue / hosting.
#
# Invoke with:
#
#   bin/rails runner "require Rails.root.join('db/seeds/seed_saas_chart_of_accounts.rb').to_s; SaasChartOfAccountsSeeder.seed(Company.find(<id>))"

class SaasChartOfAccountsSeeder
  def self.seed(company)
    accounts = [
      # ═══════════════════════════════════════════════════════
      # ASSETS (1000-1999)
      # ═══════════════════════════════════════════════════════
      { number: '1000', name: 'Cash & Bank Accounts', type: 'asset', header: true },
      { number: '1010', name: 'Operating Checking', type: 'asset', sub: 'bank' },
      { number: '1020', name: 'Savings / Reserve', type: 'asset', sub: 'bank' },
      { number: '1030', name: 'Payment Processor Clearing', type: 'asset', sub: 'bank' },
      { number: '1040', name: 'Petty Cash', type: 'asset', sub: 'bank' },

      { number: '1100', name: 'Accounts Receivable', type: 'asset', header: true },
      { number: '1110', name: 'Customer Receivables', type: 'asset', sub: 'accounts_receivable', system: true },
      { number: '1120', name: 'Other Receivables', type: 'asset', sub: 'accounts_receivable' },

      { number: '1200', name: 'Prepaid Expenses & Deposits', type: 'asset', header: true },
      { number: '1210', name: 'Prepaid Software & Subscriptions', type: 'asset', sub: 'prepaid' },
      { number: '1220', name: 'Prepaid Insurance', type: 'asset', sub: 'prepaid' },
      { number: '1230', name: 'Security Deposits', type: 'asset', sub: 'prepaid' },

      { number: '1300', name: 'Fixed Assets', type: 'asset', header: true },
      { number: '1310', name: 'Computers & Equipment', type: 'asset', sub: 'fixed_asset' },
      { number: '1320', name: 'Furniture & Fixtures', type: 'asset', sub: 'fixed_asset' },
      { number: '1330', name: 'Leasehold Improvements', type: 'asset', sub: 'fixed_asset' },
      { number: '1340', name: 'Capitalized Software Development', type: 'asset', sub: 'fixed_asset' },

      { number: '1400', name: 'Accumulated Depreciation', type: 'asset', header: true },
      { number: '1410', name: 'Accum. Depreciation – Equipment', type: 'asset', sub: 'accumulated_depreciation' },
      { number: '1420', name: 'Accum. Amortization – Capitalized Software', type: 'asset', sub: 'accumulated_depreciation' },

      # ═══════════════════════════════════════════════════════
      # LIABILITIES (2000-2999)
      # ═══════════════════════════════════════════════════════
      { number: '2000', name: 'Accounts Payable', type: 'liability', header: true },
      { number: '2010', name: 'Accounts Payable', type: 'liability', sub: 'accounts_payable', system: true },

      { number: '2100', name: 'Other Current Liabilities', type: 'liability', header: true },
      { number: '2110', name: 'Company Credit Card', type: 'liability', sub: 'current_liability' },
      { number: '2120', name: 'Accrued Expenses', type: 'liability', sub: 'current_liability' },
      { number: '2130', name: 'Accrued Payroll', type: 'liability', sub: 'current_liability' },
      { number: '2140', name: 'Payroll Taxes Payable', type: 'liability', sub: 'current_liability' },

      { number: '2300', name: 'Taxes Payable', type: 'liability', header: true },
      { number: '2310', name: 'Sales Tax Payable', type: 'liability', sub: 'current_liability', system: true },
      { number: '2320', name: 'Income Tax Payable', type: 'liability', sub: 'current_liability' },

      { number: '2400', name: 'Deferred Revenue', type: 'liability', header: true },
      { number: '2410', name: 'Deferred Subscription Revenue', type: 'liability', sub: 'current_liability' },
      { number: '2420', name: 'Deferred Setup / Onboarding Revenue', type: 'liability', sub: 'current_liability' },

      { number: '2500', name: 'Long-Term Liabilities', type: 'liability', header: true },
      { number: '2510', name: 'Notes Payable', type: 'liability', sub: 'long_term_liability' },

      # ═══════════════════════════════════════════════════════
      # EQUITY (3000-3999)
      # ═══════════════════════════════════════════════════════
      { number: '3000', name: 'Equity', type: 'equity', header: true },
      { number: '3010', name: 'Common Stock', type: 'equity', sub: 'owners_equity' },
      { number: '3020', name: 'Additional Paid-In Capital', type: 'equity', sub: 'owners_equity' },
      { number: '3030', name: 'Owner / Member Distributions', type: 'equity', sub: 'owners_equity' },
      { number: '3200', name: 'Retained Earnings', type: 'equity', sub: 'retained_earnings', system: true },

      # ═══════════════════════════════════════════════════════
      # REVENUE (4000-4999)
      # ═══════════════════════════════════════════════════════
      { number: '4000', name: 'Subscription Revenue', type: 'revenue', header: true },
      { number: '4010', name: 'Subscription Revenue – Monthly', type: 'revenue', sub: 'service_revenue' },
      { number: '4020', name: 'Subscription Revenue – Annual', type: 'revenue', sub: 'service_revenue' },
      { number: '4030', name: 'Usage & Overage Revenue', type: 'revenue', sub: 'service_revenue' },

      { number: '4100', name: 'Services Revenue', type: 'revenue', header: true },
      { number: '4110', name: 'Setup & Onboarding Fees', type: 'revenue', sub: 'service_revenue' },
      { number: '4120', name: 'Professional Services', type: 'revenue', sub: 'service_revenue' },
      { number: '4130', name: 'Training Revenue', type: 'revenue', sub: 'service_revenue' },

      { number: '4200', name: 'Other Revenue', type: 'revenue', header: true },
      { number: '4210', name: 'Discounts & Refunds', type: 'revenue', sub: 'other_revenue' },
      { number: '4220', name: 'Other Income', type: 'revenue', sub: 'other_revenue' },

      # ═══════════════════════════════════════════════════════
      # COST OF REVENUE (5000-5999)
      # ═══════════════════════════════════════════════════════
      { number: '5000', name: 'Cost of Revenue', type: 'expense', header: true },
      { number: '5010', name: 'Hosting & Infrastructure', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5020', name: 'Third-Party Software & APIs', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5030', name: 'Payment Processing Fees', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5040', name: 'Customer Support & Success', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5050', name: 'Email & SMS / Communications', type: 'expense', sub: 'cost_of_goods_sold' },

      # ═══════════════════════════════════════════════════════
      # OPERATING EXPENSES (6000-7999)
      # ═══════════════════════════════════════════════════════
      { number: '6000', name: 'Sales & Marketing', type: 'expense', header: true },
      { number: '6010', name: 'Salaries – Sales & Marketing', type: 'expense', sub: 'payroll_expense' },
      { number: '6020', name: 'Advertising & Promotion', type: 'expense', sub: 'operating_expense' },
      { number: '6030', name: 'Sales Commissions', type: 'expense', sub: 'operating_expense' },
      { number: '6040', name: 'Marketing Software & Tools', type: 'expense', sub: 'operating_expense' },

      { number: '6100', name: 'Research & Development', type: 'expense', header: true },
      { number: '6110', name: 'Salaries – Engineering & Product', type: 'expense', sub: 'payroll_expense' },
      { number: '6120', name: 'Contractors – Development', type: 'expense', sub: 'operating_expense' },
      { number: '6130', name: 'Development Tools & Software', type: 'expense', sub: 'operating_expense' },

      { number: '6200', name: 'General & Administrative', type: 'expense', header: true },
      { number: '6210', name: 'Salaries – G&A', type: 'expense', sub: 'payroll_expense' },
      { number: '6220', name: 'Payroll Taxes & Benefits', type: 'expense', sub: 'payroll_expense' },
      { number: '6230', name: 'Rent & Utilities', type: 'expense', sub: 'operating_expense' },
      { number: '6240', name: 'Office Supplies', type: 'expense', sub: 'operating_expense' },
      { number: '6250', name: 'Software Subscriptions (Internal)', type: 'expense', sub: 'operating_expense' },
      { number: '6260', name: 'Legal & Professional Fees', type: 'expense', sub: 'operating_expense' },
      { number: '6270', name: 'Insurance', type: 'expense', sub: 'operating_expense' },
      { number: '6280', name: 'Bank & Merchant Fees', type: 'expense', sub: 'operating_expense' },
      { number: '6290', name: 'Travel & Meals', type: 'expense', sub: 'operating_expense' },

      # ═══════════════════════════════════════════════════════
      # OTHER INCOME & EXPENSE (8000-8999)
      # ═══════════════════════════════════════════════════════
      { number: '8000', name: 'Other Income & Expense', type: 'expense', header: true },
      { number: '8010', name: 'Depreciation & Amortization', type: 'expense', sub: 'other_expense' },
      { number: '8020', name: 'Interest Expense', type: 'expense', sub: 'other_expense' },
      { number: '8030', name: 'Income Tax Expense', type: 'expense', sub: 'other_expense' },
      { number: '8040', name: 'Other / Miscellaneous Expense', type: 'expense', sub: 'other_expense' },
    ]

    parent_ids = {}
    position = 0

    accounts.each do |acct|
      position += 1
      parent_number = acct[:number][0..-3] + '00'
      parent_id = (acct[:header] || acct[:number] == parent_number) ? nil : parent_ids[parent_number]

      record = company.chart_of_accounts.find_or_create_by!(
        account_number: acct[:number]
      ) do |a|
        a.name = acct[:name]
        a.account_type = acct[:type]
        a.sub_type = acct[:sub]
        a.is_header = acct[:header] || false
        a.is_system = acct[:system] || false
        a.parent_id = parent_id
        a.position = position
      end

      parent_ids[acct[:number]] = record.id if acct[:header]
    end

    settings = AccountingSettings.for_company(company)
    settings.update!(
      retained_earnings_account: company.chart_of_accounts.find_by(account_number: '3200'),
      default_ar_account: company.chart_of_accounts.find_by(account_number: '1110'),
      default_ap_account: company.chart_of_accounts.find_by(account_number: '2010'),
      default_sales_revenue_account: company.chart_of_accounts.find_by(account_number: '4010'),
      default_cogs_account: company.chart_of_accounts.find_by(account_number: '5010'),
      default_sales_tax_payable_account: company.chart_of_accounts.find_by(account_number: '2310')
    )

    puts "Seeded #{accounts.count} SaaS chart of accounts for company #{company.name}"
  end
end
