# frozen_string_literal: true

# Idempotent seeder for the default Chart of Accounts for a manufactured-home
# dealer. Invoke with:
#
#   bin/rails runner "DefaultChartOfAccountsSeeder.seed(Company.find(<id>))"

class DefaultChartOfAccountsSeeder
  def self.seed(company)
    accounts = [
      # ═══════════════════════════════════════════════════════
      # ASSETS (1000-1999)
      # ═══════════════════════════════════════════════════════
      { number: '1000', name: 'Cash & Bank Accounts', type: 'asset', header: true },
      { number: '1010', name: 'Operating Checking', type: 'asset', sub: 'bank' },
      { number: '1020', name: 'Payroll Checking', type: 'asset', sub: 'bank' },
      { number: '1030', name: 'Savings / Reserve', type: 'asset', sub: 'bank' },
      { number: '1040', name: 'Petty Cash', type: 'asset', sub: 'bank' },

      { number: '1100', name: 'Accounts Receivable', type: 'asset', header: true },
      { number: '1110', name: 'Customer Receivables', type: 'asset', sub: 'accounts_receivable', system: true },
      { number: '1120', name: 'Employee Receivables', type: 'asset', sub: 'accounts_receivable' },
      { number: '1130', name: 'Other Receivables', type: 'asset', sub: 'accounts_receivable' },

      { number: '1200', name: 'Inventory', type: 'asset', header: true },
      { number: '1210', name: 'New Home Inventory', type: 'asset', sub: 'inventory' },
      { number: '1220', name: 'Used Home Inventory', type: 'asset', sub: 'inventory' },
      { number: '1230', name: 'Parts Inventory', type: 'asset', sub: 'inventory' },
      { number: '1240', name: 'Reconditioning WIP', type: 'asset', sub: 'inventory' },
      { number: '1250', name: 'Land / Lot Inventory', type: 'asset', sub: 'inventory' },

      { number: '1300', name: 'Prepaid & Deposits', type: 'asset', header: true },
      { number: '1310', name: 'Prepaid Insurance', type: 'asset', sub: 'prepaid' },
      { number: '1320', name: 'Customer Deposits Held', type: 'asset', sub: 'prepaid' },
      { number: '1330', name: 'Security Deposits', type: 'asset', sub: 'prepaid' },

      { number: '1400', name: 'Fixed Assets', type: 'asset', header: true },
      { number: '1410', name: 'Vehicles & Equipment', type: 'asset', sub: 'fixed_asset' },
      { number: '1420', name: 'Furniture & Fixtures', type: 'asset', sub: 'fixed_asset' },
      { number: '1430', name: 'Leasehold Improvements', type: 'asset', sub: 'fixed_asset' },
      { number: '1490', name: 'Accumulated Depreciation', type: 'asset', sub: 'accumulated_depreciation' },

      # ═══════════════════════════════════════════════════════
      # LIABILITIES (2000-2999)
      # ═══════════════════════════════════════════════════════
      { number: '2000', name: 'Accounts Payable', type: 'liability', header: true },
      { number: '2010', name: 'Trade Payables', type: 'liability', sub: 'accounts_payable', system: true },
      { number: '2020', name: 'Accrued Expenses', type: 'liability', sub: 'accounts_payable' },

      { number: '2100', name: 'Floor Plan', type: 'liability', header: true },
      { number: '2110', name: 'Floor Plan - New Homes', type: 'liability', sub: 'current_liability' },
      { number: '2120', name: 'Floor Plan - Used Homes', type: 'liability', sub: 'current_liability' },
      { number: '2130', name: 'Floor Plan Interest Payable', type: 'liability', sub: 'current_liability' },

      { number: '2200', name: 'Sales Tax Payable', type: 'liability', header: true },
      { number: '2210', name: 'State Sales Tax', type: 'liability', sub: 'current_liability', system: true },
      { number: '2220', name: 'County Sales Tax', type: 'liability', sub: 'current_liability' },
      { number: '2230', name: 'City/Local Sales Tax', type: 'liability', sub: 'current_liability' },

      { number: '2300', name: 'Payroll Liabilities', type: 'liability', sub: 'current_liability' },

      { number: '2400', name: 'Customer Deposits', type: 'liability', header: true },
      { number: '2410', name: 'Earnest Money Deposits', type: 'liability', sub: 'current_liability' },
      { number: '2420', name: 'Progress Payment Deposits', type: 'liability', sub: 'current_liability' },

      { number: '2500', name: 'Notes Payable', type: 'liability', header: true },
      { number: '2510', name: 'Short-Term Notes', type: 'liability', sub: 'current_liability' },
      { number: '2520', name: 'Long-Term Notes', type: 'liability', sub: 'long_term_liability' },

      { number: '2600', name: 'Warranty Reserve', type: 'liability', sub: 'current_liability' },

      # ═══════════════════════════════════════════════════════
      # EQUITY (3000-3999)
      # ═══════════════════════════════════════════════════════
      { number: '3000', name: "Owner's Equity / Capital", type: 'equity', sub: 'owners_equity' },
      { number: '3100', name: "Owner's Draw", type: 'equity', sub: 'owners_equity' },
      { number: '3200', name: 'Retained Earnings', type: 'equity', sub: 'retained_earnings', system: true },
      { number: '3300', name: 'Current Year Earnings', type: 'equity', sub: 'retained_earnings' },

      # ═══════════════════════════════════════════════════════
      # REVENUE (4000-4999)
      # ═══════════════════════════════════════════════════════
      { number: '4000', name: 'Home Sales', type: 'revenue', header: true },
      { number: '4010', name: 'New Home Sales', type: 'revenue', sub: 'sales_revenue', system: true },
      { number: '4020', name: 'Used Home Sales', type: 'revenue', sub: 'sales_revenue' },
      { number: '4030', name: 'Land/Lot Sales', type: 'revenue', sub: 'sales_revenue' },

      { number: '4100', name: 'F&I Income', type: 'revenue', header: true },
      { number: '4110', name: 'Extended Warranty Revenue', type: 'revenue', sub: 'other_revenue' },
      { number: '4120', name: 'Insurance Products', type: 'revenue', sub: 'other_revenue' },
      { number: '4130', name: 'GAP Coverage', type: 'revenue', sub: 'other_revenue' },
      { number: '4140', name: 'Finance Reserve (Dealer Participation)', type: 'revenue', sub: 'other_revenue' },

      { number: '4200', name: 'Service Revenue', type: 'revenue', header: true },
      { number: '4210', name: 'Service Labor', type: 'revenue', sub: 'service_revenue' },
      { number: '4220', name: 'Parts Sales', type: 'revenue', sub: 'service_revenue' },
      { number: '4230', name: 'Warranty Labor Reimbursement', type: 'revenue', sub: 'service_revenue' },

      { number: '4300', name: 'Delivery & Setup Income', type: 'revenue', sub: 'other_revenue' },
      { number: '4400', name: 'Lot Rent Income', type: 'revenue', sub: 'other_revenue' },

      { number: '4500', name: 'Other Income', type: 'revenue', header: true },
      { number: '4510', name: 'Late Fees', type: 'revenue', sub: 'other_revenue' },
      { number: '4520', name: 'Document Fees', type: 'revenue', sub: 'other_revenue' },
      { number: '4530', name: 'Interest Income', type: 'revenue', sub: 'other_revenue' },

      # ═══════════════════════════════════════════════════════
      # COST OF GOODS SOLD (5000-5999)
      # ═══════════════════════════════════════════════════════
      { number: '5000', name: 'Cost of Homes Sold', type: 'expense', header: true },
      { number: '5010', name: 'New Home Cost', type: 'expense', sub: 'cost_of_goods_sold', system: true },
      { number: '5020', name: 'Used Home Cost', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5030', name: 'Land/Lot Cost', type: 'expense', sub: 'cost_of_goods_sold' },

      { number: '5100', name: 'Reconditioning Costs', type: 'expense', header: true },
      { number: '5110', name: 'Reconditioning Materials', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5120', name: 'Reconditioning Labor', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5130', name: 'Reconditioning Subcontractor', type: 'expense', sub: 'cost_of_goods_sold' },

      { number: '5200', name: 'Delivery & Setup Costs', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5300', name: 'Floor Plan Interest Expense', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5400', name: 'Parts Cost of Goods Sold', type: 'expense', sub: 'cost_of_goods_sold' },
      { number: '5500', name: 'Warranty Expense', type: 'expense', sub: 'cost_of_goods_sold' },

      # ═══════════════════════════════════════════════════════
      # OPERATING EXPENSES (6000-8999)
      # ═══════════════════════════════════════════════════════
      { number: '6000', name: 'Compensation & Benefits', type: 'expense', header: true },
      { number: '6010', name: 'Sales Salaries & Commissions', type: 'expense', sub: 'payroll_expense' },
      { number: '6020', name: 'Admin Salaries', type: 'expense', sub: 'payroll_expense' },
      { number: '6030', name: 'Service Tech Pay', type: 'expense', sub: 'payroll_expense' },
      { number: '6040', name: 'Payroll Taxes', type: 'expense', sub: 'payroll_expense' },
      { number: '6050', name: 'Employee Benefits', type: 'expense', sub: 'payroll_expense' },

      { number: '6100', name: 'Advertising & Marketing', type: 'expense', sub: 'operating_expense' },
      { number: '6200', name: 'Rent & Occupancy', type: 'expense', sub: 'operating_expense' },
      { number: '6300', name: 'Utilities', type: 'expense', sub: 'operating_expense' },
      { number: '6400', name: 'Insurance', type: 'expense', sub: 'operating_expense' },
      { number: '6500', name: 'Office & Admin', type: 'expense', sub: 'operating_expense' },
      { number: '6600', name: 'Vehicle Expense', type: 'expense', sub: 'operating_expense' },
      { number: '6700', name: 'Professional Fees', type: 'expense', sub: 'operating_expense' },
      { number: '6800', name: 'Depreciation', type: 'expense', sub: 'operating_expense' },
      { number: '6900', name: 'Interest Expense (Non-Floor Plan)', type: 'expense', sub: 'other_expense' },
      { number: '7000', name: 'Other Operating Expenses', type: 'expense', sub: 'other_expense' },

      { number: '8000', name: 'Non-Operating Items', type: 'expense', header: true },
      { number: '8100', name: 'Gain/Loss on Asset Sale', type: 'expense', sub: 'other_expense' },
      { number: '8200', name: 'Miscellaneous', type: 'expense', sub: 'other_expense' },
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
      default_sales_tax_payable_account: company.chart_of_accounts.find_by(account_number: '2210')
    )

    puts "Seeded #{accounts.count} chart of accounts for company #{company.name}"
  end
end
