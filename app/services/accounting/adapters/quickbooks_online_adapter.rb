# frozen_string_literal: true

module Accounting
  module Adapters
    # Reads a QuickBooks Online company for the import wizard and the
    # migration wizard (Accounting::QboMigration).
    #
    # Every list query pages with STARTPOSITION/MAXRESULTS until a short page
    # comes back. QuickBooks caps a page at 1000 rows, and the old adapter
    # read one page and silently dropped the rest.
    #
    # Balances come from the Trial Balance report as of a date, never from an
    # account's CurrentBalance (which is today's balance, not the cutover's).
    class QuickbooksOnlineAdapter
      PAGE_SIZE = 1000

      attr_reader :source_name

      # client: anything that answers query(sql), report(name, params) and
      # company_info. Defaults to the live API client; the migration's fixture
      # mode passes Accounting::QboMigration::FixtureClient.
      def initialize(company, connection, config = {}, client: nil, page_size: PAGE_SIZE)
        @company = company
        @connection = connection
        @client = client || Quickbooks::Client.new(connection)
        @config = config
        @page_size = page_size
        @source_name = 'QuickBooks Online'
      end

      # ── Counts (import wizard preview) ─────────────────────────

      def count_accounts
        count('Account', 'Active IN (true, false)')
      end

      def count_contacts
        count('Customer', 'Active = true')
      end

      def count_vendors
        count('Vendor', 'Active = true')
      end

      def count_open_invoices
        count('Invoice', "Balance > '0'")
      end

      # ── Paging ─────────────────────────────────────────────────

      # Every row of an entity, one page at a time.
      def query_all(entity, where = nil)
        rows = []
        position = 1
        loop do
          sql = +"SELECT * FROM #{entity}"
          sql << " WHERE #{where}" if where.present?
          sql << " STARTPOSITION #{position} MAXRESULTS #{@page_size}"
          page = Array(@client.query(sql).dig('QueryResponse', entity))
          rows.concat(page)
          break if page.size < @page_size

          position += @page_size
        end
        rows
      end

      # ── Company ────────────────────────────────────────────────

      def company_info
        @company_info ||= begin
          info = @client.company_info || {}
          info['CompanyInfo'] || info.dig('QueryResponse', 'CompanyInfo', 0) || {}
        end
      end

      def company_name
        company_info['CompanyName'] || company_info['LegalName']
      end

      # 1..12. QuickBooks reports the month by name ("January").
      def fiscal_year_start_month
        name = company_info['FiscalYearStartMonth'].to_s
        Date::MONTHNAMES.index(name.capitalize) || 1
      end

      def fiscal_year_start(as_of)
        month = fiscal_year_start_month
        year = as_of.month >= month ? as_of.year : as_of.year - 1
        Date.new(year, month, 1)
      end

      # ── Chart of accounts ──────────────────────────────────────

      # Active AND inactive accounts. QuickBooks returns active accounts only
      # unless the query asks for both, and an inactive account can still
      # carry a balance (the old adapter dropped it, and its balance with it).
      def fetch_accounts
        accounts = query_all('Account', 'Active IN (true, false)')

        @parent_map = {}
        accounts.map do |acct|
          @parent_map[acct['Id']] = acct['ParentRef']['value'] if acct['SubAccount'] && acct['ParentRef']

          {
            external_id: acct['Id'],
            account_number: acct['AcctNum'].presence,
            name: acct['Name'],
            fully_qualified_name: acct['FullyQualifiedName'],
            qbo_type: acct['AccountType'],
            qbo_sub_type: acct['AccountSubType'],
            account_type: self.class.map_qb_type(acct['AccountType']),
            sub_type: self.class.map_qb_sub_type(acct['AccountSubType'], acct['AccountType']),
            description: acct['Description'],
            is_header: false,
            is_active: acct['Active'] != false,
            parent_external_id: acct.dig('ParentRef', 'value'),
            current_balance: acct['CurrentBalance']&.to_d
          }
        end
      end

      def parent_mappings
        @parent_map || {}
      end

      # ── Trial balance ──────────────────────────────────────────

      # GET /reports/TrialBalance?start_date=&end_date=&accounting_method=Accrual
      #
      # start_date is the first day of the fiscal year holding the cutover, so
      # income and expense accounts carry year-to-date activity and Retained
      # Earnings carries prior years, which is what an opening entry dated
      # mid-year needs. Balance sheet accounts are cumulative to end_date.
      #
      # Returns { rows: [{ external_id:, name:, debit:, credit:, balance: }],
      #           total_debit:, total_credit:, start_date:, end_date: }
      # balance is debit minus credit.
      def fetch_trial_balance(as_of_date)
        start_date = fiscal_year_start(as_of_date)
        report = @client.report('TrialBalance', start_date: start_date.iso8601, end_date: as_of_date.iso8601,
                                                accounting_method: 'Accrual')
        self.class.parse_trial_balance(report).merge(start_date: start_date, end_date: as_of_date)
      end

      # Kept for Accounting::ImportService#import_opening_balances: balances
      # as of the date asked for, from the trial balance, signed in each
      # account's normal direction as the importer expects.
      def fetch_account_balances(as_of_date)
        accounts_by_id = fetch_accounts.index_by { |a| a[:external_id] }
        fetch_trial_balance(as_of_date)[:rows].filter_map do |row|
          next if row[:balance].zero?

          acct = accounts_by_id[row[:external_id]] || {}
          normal_debit = %w[asset expense].include?(acct[:account_type])
          {
            external_id: row[:external_id],
            account_number: acct[:account_number],
            account_name: acct[:name] || row[:name],
            balance: normal_debit ? row[:balance] : -row[:balance]
          }
        end
      end

      def self.parse_trial_balance(report)
        columns = Array(report.dig('Columns', 'Column'))
        debit_idx = columns.index { |c| c['ColTitle'].to_s.casecmp('Debit').zero? } || 1
        credit_idx = columns.index { |c| c['ColTitle'].to_s.casecmp('Credit').zero? } || 2

        rows = []
        totals = nil
        walk = lambda do |row_list|
          Array(row_list).each do |row|
            if row['group'] == 'GrandTotal' && row['Summary']
              data = row.dig('Summary', 'ColData') || []
              totals = { debit: money(data[debit_idx]), credit: money(data[credit_idx]) }
            end
            walk.call(row.dig('Rows', 'Row')) if row['Rows']
            data = row['ColData']
            next unless data && data[0] && data[0]['id'].present?

            debit = money(data[debit_idx])
            credit = money(data[credit_idx])
            rows << { external_id: data[0]['id'].to_s, name: data[0]['value'], debit: debit, credit: credit,
                      balance: debit - credit }
          end
        end
        walk.call(report.dig('Rows', 'Row'))

        {
          rows: rows,
          total_debit: totals ? totals[:debit] : rows.sum(BigDecimal('0')) { |r| r[:debit] },
          total_credit: totals ? totals[:credit] : rows.sum(BigDecimal('0')) { |r| r[:credit] }
        }
      end

      def self.money(col)
        value = col.is_a?(Hash) ? col['value'] : col
        return BigDecimal('0') if value.blank?

        BigDecimal(value.to_s.delete(','))
      rescue ArgumentError
        BigDecimal('0')
      end

      # ── Customers and vendors ──────────────────────────────────

      def fetch_contacts
        query_all('Customer', 'Active = true').map { |c| customer_hash(c) }
      end

      def fetch_customers_by_id(ids)
        by_ids('Customer', ids).map { |c| customer_hash(c) }
      end

      def fetch_vendors
        query_all('Vendor', 'Active = true').map { |v| vendor_hash(v) }
      end

      def fetch_vendors_by_id(ids)
        by_ids('Vendor', ids).map { |v| vendor_hash(v) }
      end

      # ── Open items as of a date ────────────────────────────────

      # Open invoices with their remaining balance AT the cutover, not today.
      # An invoice open at cutover may have been paid since, so Balance alone
      # undercounts: the balance at cutover is today's Balance plus whatever
      # payments dated after cutover applied to it.
      def fetch_open_invoices(as_of_date = nil)
        return query_all('Invoice', "Balance > '0'").map { |inv| invoice_hash(inv, inv['Balance']) } if as_of_date.nil?

        applied_later = linked_amounts('Payment', as_of_date, 'Invoice')
        open_now = query_all('Invoice', "Balance > '0' AND TxnDate <= '#{as_of_date.iso8601}'")
        seen = open_now.map { |i| i['Id'] }.to_set
        paid_since = by_ids('Invoice', applied_later.keys.reject { |id| seen.include?(id) })
                     .select { |i| i['TxnDate'].present? && Date.parse(i['TxnDate']) <= as_of_date }

        (open_now + paid_since).filter_map do |inv|
          balance = inv['Balance'].to_d + applied_later.fetch(inv['Id'].to_s, 0)
          next if balance <= 0

          invoice_hash(inv, balance)
        end
      end

      # Open bills as of the cutover, the same way, through BillPayment.
      def fetch_open_bills(as_of_date)
        applied_later = linked_amounts('BillPayment', as_of_date, 'Bill')
        open_now = query_all('Bill', "Balance > '0' AND TxnDate <= '#{as_of_date.iso8601}'")
        seen = open_now.map { |b| b['Id'] }.to_set
        paid_since = by_ids('Bill', applied_later.keys.reject { |id| seen.include?(id) })
                     .select { |b| b['TxnDate'].present? && Date.parse(b['TxnDate']) <= as_of_date }

        (open_now + paid_since).filter_map do |bill|
          balance = bill['Balance'].to_d + applied_later.fetch(bill['Id'].to_s, 0)
          next if balance <= 0

          {
            external_id: bill['Id'],
            doc_number: bill['DocNumber'],
            date: parse_date(bill['TxnDate']),
            due_date: parse_date(bill['DueDate']),
            vendor_external_id: bill.dig('VendorRef', 'value'),
            vendor_name: bill.dig('VendorRef', 'name'),
            total: bill['TotalAmt'].to_d,
            balance: balance,
            memo: bill['PrivateNote'],
            expense_account_external_id: Array(bill['Line']).filter_map { |l|
              l.dig('AccountBasedExpenseLineDetail', 'AccountRef', 'value')
            }.first
          }
        end
      end

      # Unapplied vendor credits as of the cutover. They lower AP.
      def fetch_open_vendor_credits(as_of_date)
        applied_later = linked_amounts('BillPayment', as_of_date, 'VendorCredit')
        query_all('VendorCredit', "TxnDate <= '#{as_of_date.iso8601}'").filter_map do |vc|
          balance = vc['Balance'].to_d + applied_later.fetch(vc['Id'].to_s, 0)
          next if balance <= 0

          {
            external_id: vc['Id'],
            doc_number: vc['DocNumber'],
            date: parse_date(vc['TxnDate']),
            vendor_external_id: vc.dig('VendorRef', 'value'),
            vendor_name: vc.dig('VendorRef', 'name'),
            total: vc['TotalAmt'].to_d,
            balance: balance
          }
        end
      end

      # ── Uncleared bank items ───────────────────────────────────

      # QuickBooks Online's v3 entities carry no cleared or reconciled flag.
      # The TransactionList report can FILTER by it (cleared=Uncleared), so
      # this reads uncleared bank and card transactions dated on or before the
      # cutover. Two limits, both shown to the person as suggestions to check:
      # an item that was uncleared at cutover but has cleared since reads as
      # cleared today and is missed, and the report has no account id filter,
      # so rows are matched to accounts by name.
      #
      # Returns { account name => [{ external_id:, date:, kind:, payee:, reference:, amount: }] }
      def fetch_uncleared_items(as_of_date)
        report = @client.report('TransactionList',
                                start_date: (as_of_date - 2.years).iso8601, end_date: as_of_date.iso8601,
                                cleared: 'Uncleared', source_account_type: 'Bank,CreditCard',
                                columns: 'tx_date,txn_type,doc_num,name,memo,account_name,subt_nat_amount')
        self.class.parse_transaction_list(report)
      end

      def self.parse_transaction_list(report)
        columns = Array(report.dig('Columns', 'Column')).map do |c|
          key = Array(c['MetaData']).find { |m| m['Name'] == 'ColKey' }&.dig('Value')
          key.presence || c['ColTitle'].to_s.parameterize(separator: '_')
        end
        idx = ->(*names) { names.filter_map { |n| columns.index(n) }.first }
        date_i = idx.call('tx_date', 'date')
        type_i = idx.call('txn_type', 'transaction_type')
        num_i = idx.call('doc_num', 'num')
        name_i = idx.call('name')
        acct_i = idx.call('account_name', 'account')
        amt_i = idx.call('subt_nat_amount', 'amount')

        out = Hash.new { |h, k| h[k] = [] }
        walk = lambda do |row_list|
          Array(row_list).each do |row|
            walk.call(row.dig('Rows', 'Row')) if row['Rows']
            data = row['ColData']
            next unless data && date_i && data[date_i] && data[date_i]['value'].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

            type = type_i ? data[type_i]&.dig('value').to_s : ''
            amount = amt_i ? money(data[amt_i]) : BigDecimal('0')
            out[acct_i ? data[acct_i]&.dig('value').to_s : ''] << {
              external_id: type_i ? data[type_i]&.dig('id').to_s.presence : nil,
              date: data[date_i]['value'],
              kind: uncleared_kind(type, amount),
              payee: name_i ? data[name_i]&.dig('value').presence : nil,
              reference: num_i ? data[num_i]&.dig('value').presence : nil,
              amount: amount.abs
            }
          end
        end
        walk.call(report.dig('Rows', 'Row'))
        out
      end

      # Money out of the account is a check (an outstanding payment, or a card
      # charge); money in is a deposit (in transit, or a card payment or
      # refund). The transaction type decides when it is clear, else the sign.
      def self.uncleared_kind(txn_type, amount)
        t = txn_type.to_s.downcase
        return 'check' if t.match?(/check|expense|bill payment|cash purchase|credit card charge/)
        return 'deposit' if t.match?(/deposit|payment|sales receipt|refund|credit card credit/)

        if amount.negative? then 'check'
        elsif amount.positive? then 'deposit'
        else 'other'
        end
      end

      # ── Type mapping ───────────────────────────────────────────

      def self.map_qb_type(qb_type)
        case qb_type
        when 'Bank', 'Other Current Asset', 'Fixed Asset', 'Other Asset', 'Accounts Receivable'
          'asset'
        when 'Other Current Liability', 'Long Term Liability', 'Accounts Payable', 'Credit Card'
          'liability'
        when 'Equity'
          'equity'
        when 'Income', 'Other Income'
          'revenue'
        else
          'expense'
        end
      end

      def self.map_qb_sub_type(qb_sub_type, qb_type)
        return 'bank' if qb_type == 'Bank'
        return 'accounts_receivable' if qb_type == 'Accounts Receivable'
        return 'accounts_payable' if qb_type == 'Accounts Payable'
        return 'cost_of_goods_sold' if qb_type == 'Cost of Goods Sold'
        return 'current_liability' if qb_type == 'Credit Card'
        return 'long_term_liability' if qb_type == 'Long Term Liability'
        return 'other_revenue' if qb_type == 'Other Income'
        return 'other_expense' if qb_type == 'Other Expense'

        case qb_sub_type
        when 'Checking', 'Savings', 'MoneyMarket', 'TrustAccounts', 'CashOnHand' then 'bank'
        when 'Inventory' then 'inventory'
        when 'PrepaidExpenses' then 'prepaid'
        when 'AccumulatedDepreciation' then 'accumulated_depreciation'
        when 'RetainedEarnings' then 'retained_earnings'
        when 'OpeningBalanceEquity', 'PartnersEquity', 'OwnersEquity', 'PartnerContributions',
             'PartnerDistributions', 'OwnerDraws' then 'owners_equity'
        when 'SalesOfProductIncome' then 'sales_revenue'
        when 'ServiceFeeIncome' then 'service_revenue'
        when 'PayrollExpenses' then 'payroll_expense'
        else
          case qb_type
          when 'Fixed Asset' then 'fixed_asset'
          when 'Other Current Liability' then 'current_liability'
          when 'Income' then 'sales_revenue'
          when 'Equity' then 'owners_equity'
          when 'Other Current Asset', 'Other Asset' then 'prepaid'
          else 'operating_expense'
          end
        end
      end

      # Instance shims so older callers keep working.
      def map_qb_type(qb_type) = self.class.map_qb_type(qb_type)
      def map_qb_sub_type(sub, type) = self.class.map_qb_sub_type(sub, type)

      private

      def money(col) = self.class.money(col)

      def count(entity, where)
        result = @client.query("SELECT COUNT(*) FROM #{entity} WHERE #{where}")
        result.dig('QueryResponse', 'totalCount') || 0
      rescue => e
        Rails.logger.warn("[QBOAdapter] count #{entity} failed: #{e.message}")
        0
      end

      def by_ids(entity, ids)
        ids = Array(ids).compact.map(&:to_s).uniq
        ids.each_slice(100).flat_map do |slice|
          list = slice.map { |id| "'#{id.delete("'")}'" }.join(', ')
          query_all(entity, "Id IN (#{list})")
        end
      end

      # { txn id => amount that `entity` rows (Payment or BillPayment) dated
      #   after the cutover applied to transactions of linked_type }
      def linked_amounts(entity, as_of_date, linked_type)
        totals = Hash.new(BigDecimal('0'))
        query_all(entity, "TxnDate > '#{as_of_date.iso8601}'").each do |pmt|
          Array(pmt['Line']).each do |line|
            Array(line['LinkedTxn']).each do |link|
              next unless link['TxnType'] == linked_type

              totals[link['TxnId'].to_s] += line['Amount'].to_d
            end
          end
        end
        totals
      end

      def parse_date(value)
        value.present? ? Date.parse(value) : nil
      end

      def customer_hash(cust)
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
          zip: addr['PostalCode'],
          active: cust['Active'] != false
        }
      end

      def vendor_hash(vendor)
        addr = vendor['BillAddr'] || {}
        {
          external_id: vendor['Id'],
          name: vendor['DisplayName'],
          company_name: vendor['CompanyName'],
          email: vendor.dig('PrimaryEmailAddr', 'Address'),
          phone: vendor.dig('PrimaryPhone', 'FreeFormNumber'),
          street: addr['Line1'],
          city: addr['City'],
          state: addr['CountrySubDivisionCode'],
          zip: addr['PostalCode'],
          account_number: vendor['AcctNum'],
          active: vendor['Active'] != false
        }
      end

      def invoice_hash(inv, balance)
        {
          external_id: inv['Id'],
          invoice_number: inv['DocNumber'],
          date: parse_date(inv['TxnDate']),
          due_date: parse_date(inv['DueDate']),
          customer_external_id: inv.dig('CustomerRef', 'value'),
          customer_name: inv.dig('CustomerRef', 'name'),
          customer_email: inv.dig('BillEmail', 'Address'),
          amount: inv['TotalAmt']&.to_d,
          tax: inv.dig('TxnTaxDetail', 'TotalTax')&.to_d || 0,
          total: inv['TotalAmt']&.to_d,
          balance: balance.to_d
        }
      end
    end
  end
end
