# frozen_string_literal: true

module Accounting
  module Adapters
    class QuickbooksOnlineAdapter
      attr_reader :source_name

      def initialize(company, connection, config = {})
        @company = company
        @connection = connection
        @client = Quickbooks::Client.new(connection)
        @config = config
        @source_name = 'QuickBooks Online'
      end

      def count_accounts
        result = @client.query("SELECT COUNT(*) FROM Account")
        result.dig('QueryResponse', 'totalCount') || 0
      rescue => e
        Rails.logger.warn("[QBOAdapter] count_accounts failed: #{e.message}")
        0
      end

      def count_contacts
        result = @client.query("SELECT COUNT(*) FROM Customer WHERE Active = true")
        result.dig('QueryResponse', 'totalCount') || 0
      rescue
        0
      end

      def count_vendors
        result = @client.query("SELECT COUNT(*) FROM Vendor WHERE Active = true")
        result.dig('QueryResponse', 'totalCount') || 0
      rescue
        0
      end

      def count_open_invoices
        result = @client.query("SELECT COUNT(*) FROM Invoice WHERE Balance > '0'")
        result.dig('QueryResponse', 'totalCount') || 0
      rescue
        0
      end

      def fetch_accounts
        result = @client.query("SELECT * FROM Account WHERE Active = true MAXRESULTS 1000")
        accounts = result.dig('QueryResponse', 'Account') || []

        @parent_map = {}
        accounts.map do |acct|
          if acct['SubAccount'] && acct['ParentRef']
            @parent_map[acct['Id']] = acct['ParentRef']['value']
          end

          {
            external_id: acct['Id'],
            account_number: acct['AcctNum'],
            name: acct['Name'],
            account_type: map_qb_type(acct['AccountType']),
            sub_type: map_qb_sub_type(acct['AccountSubType'], acct['AccountType']),
            description: acct['Description'],
            is_header: false,
            is_active: acct['Active'] != false,
            balance: acct['CurrentBalance']&.to_d
          }
        end
      end

      def parent_mappings
        @parent_map || {}
      end

      def fetch_contacts
        result = @client.query("SELECT * FROM Customer WHERE Active = true MAXRESULTS 1000")
        customers = result.dig('QueryResponse', 'Customer') || []

        customers.map do |cust|
          addr = cust['BillAddr'] || {}
          {
            external_id: cust['Id'],
            name: cust['DisplayName'],
            first_name: cust['GivenName'],
            last_name: cust['FamilyName'],
            company_name: cust['CompanyName'],
            email: cust.dig('PrimaryEmailAddr', 'Address'),
            phone: cust.dig('PrimaryPhone', 'FreeFormNumber'),
            street: addr['Line1'],
            city: addr['City'],
            state: addr['CountrySubDivisionCode'],
            zip: addr['PostalCode']
          }
        end
      end

      def fetch_vendors
        result = @client.query("SELECT * FROM Vendor WHERE Active = true MAXRESULTS 1000")
        vendors = result.dig('QueryResponse', 'Vendor') || []

        vendors.map do |v|
          addr = v['BillAddr'] || {}
          {
            external_id: v['Id'],
            name: v['DisplayName'],
            email: v.dig('PrimaryEmailAddr', 'Address'),
            phone: v.dig('PrimaryPhone', 'FreeFormNumber'),
            street: addr['Line1'],
            city: addr['City'],
            state: addr['CountrySubDivisionCode'],
            zip: addr['PostalCode']
          }
        end
      end

      def fetch_account_balances(_as_of_date)
        result = @client.query("SELECT * FROM Account WHERE Active = true MAXRESULTS 1000")
        accounts = result.dig('QueryResponse', 'Account') || []

        accounts.filter_map do |acct|
          balance = acct['CurrentBalance']&.to_d
          next if balance.nil? || balance.zero?

          {
            external_id: acct['Id'],
            account_number: acct['AcctNum'],
            account_name: acct['Name'],
            balance: balance
          }
        end
      end

      def fetch_open_invoices
        result = @client.query("SELECT * FROM Invoice WHERE Balance > '0' MAXRESULTS 500")
        invoices = result.dig('QueryResponse', 'Invoice') || []

        invoices.map do |inv|
          {
            external_id: inv['Id'],
            invoice_number: inv['DocNumber'],
            date: inv['TxnDate'] ? Date.parse(inv['TxnDate']) : nil,
            due_date: inv['DueDate'] ? Date.parse(inv['DueDate']) : nil,
            customer_name: inv.dig('CustomerRef', 'name'),
            amount: inv['TotalAmt']&.to_d,
            tax: inv.dig('TxnTaxDetail', 'TotalTax')&.to_d || 0,
            total: inv['TotalAmt']&.to_d,
            balance: inv['Balance']&.to_d
          }
        end
      end

      private

      def map_qb_type(qb_type)
        case qb_type
        when 'Bank', 'Other Current Asset', 'Fixed Asset', 'Other Asset', 'Accounts Receivable'
          'asset'
        when 'Other Current Liability', 'Long Term Liability', 'Accounts Payable'
          'liability'
        when 'Equity'
          'equity'
        when 'Income', 'Other Income'
          'revenue'
        when 'Expense', 'Other Expense', 'Cost of Goods Sold'
          'expense'
        else
          'expense'
        end
      end

      def map_qb_sub_type(qb_sub_type, qb_type)
        return 'bank' if qb_type == 'Bank'
        return 'accounts_receivable' if qb_type == 'Accounts Receivable'
        return 'accounts_payable' if qb_type == 'Accounts Payable'
        return 'cost_of_goods_sold' if qb_type == 'Cost of Goods Sold'
        return 'fixed_asset' if qb_type == 'Fixed Asset'

        case qb_sub_type
        when 'Checking', 'Savings', 'MoneyMarket', 'TrustAccounts' then 'bank'
        when 'AccountsReceivable' then 'accounts_receivable'
        when 'AccountsPayable' then 'accounts_payable'
        when 'Inventory' then 'inventory'
        when 'PrepaidExpenses' then 'prepaid'
        when 'AccumulatedDepreciation' then 'accumulated_depreciation'
        when 'RetainedEarnings' then 'retained_earnings'
        when 'OpeningBalanceEquity', 'PartnersEquity' then 'owners_equity'
        when 'SalesOfProductIncome', 'ServiceFeeIncome' then 'sales_revenue'
        when 'SuppliesMaterialsCogs' then 'cost_of_goods_sold'
        when 'PayrollExpenses' then 'payroll_expense'
        else 'operating_expense'
        end
      end
    end
  end
end
