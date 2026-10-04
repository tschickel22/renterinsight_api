# frozen_string_literal: true

module Accounting
  module QboMigration
    # Turns the QuickBooks trial balance at cutover into the lines of one
    # opening entry, through the account mapping. Used by the preview (with
    # accounts still to be created shown by name) and by the Poster (with
    # every account resolved to an id).
    #
    # A matched bank account's balance is split so the first reconciliation
    # balances: one line for the cleared balance the bank statement shows,
    # and one line per uncleared check or deposit. The lines sum to the
    # QuickBooks balance exactly when the bank step ties.
    class OpeningEntryBuilder
      OBE_KEY = 'obe'

      # resolver: ->(row) { [key, label, chart_of_account_id_or_nil] }
      def initialize(wizard, resolver: nil)
        @wizard = wizard
        @resolver = resolver || method(:preview_resolver)
        @accounts = wizard.company.chart_of_accounts.index_by(&:id)
      end

      def build
        d = Wizard.method(:d)
        uncleared = @wizard.config['uncleared'] || {}
        matched = @wizard.matched_banks.index_by { |b| b['qbo_account_id'] }

        lines = []
        summary = {}
        aggregate = Hash.new(BigDecimal('0'))
        meta = {}

        @wizard.account_rows.each do |row|
          balance = d.call(row['tb_balance'])
          next if balance.zero?

          key, label, account_id = @resolver.call(row)
          meta[key] ||= { label: label, account_id: account_id }
          (summary[key] ||= { label: label, qbo_names: [], net: BigDecimal('0') })
          summary[key][:qbo_names] << row['qbo_name']
          summary[key][:net] += balance

          bank = matched[row['qbo_account_id']]
          state = bank && uncleared[row['qbo_account_id']]
          if state && !state['statement_balance'].nil?
            lines.concat(bank_lines(row, bank, state, key, account_id))
          else
            aggregate[key] += balance
          end
        end

        aggregate.each do |key, net|
          next if net.zero?

          names = summary[key][:qbo_names]
          lines << line(key, meta[key][:account_id], net, "Opening balance from QuickBooks: #{names.join(', ')}".first(500))
        end

        total_debit = lines.sum(BigDecimal('0')) { |l| l[:debit_amount] }
        total_credit = lines.sum(BigDecimal('0')) { |l| l[:credit_amount] }
        plug = total_debit - total_credit
        if plug.nonzero?
          lines << line(OBE_KEY, nil, -plug, 'Opening balance difference from QuickBooks')
          summary[OBE_KEY] = { label: 'Opening Balance Equity', qbo_names: [], net: -plug }
          total_debit += plug.negative? ? plug.abs : 0
          total_credit += plug.positive? ? plug : 0
        end

        rows = summary.map do |_key, s|
          { label: s[:label], qbo_names: s[:qbo_names], debit: s[:net].positive? ? s[:net] : BigDecimal('0'),
            credit: s[:net].negative? ? -s[:net] : BigDecimal('0') }
        end

        { lines: lines, rows: rows, total_debit: total_debit, total_credit: total_credit, plug: plug }
      end

      private

      def bank_lines(row, bank, state, key, account_id)
        out = []
        statement = @wizard.statement_dp(bank, state['statement_balance'])
        if statement.nonzero?
          out << line(key, account_id, statement, "Cleared balance per #{row['qbo_name']} statement at cutover",
                      bank_qbo_id: row['qbo_account_id'], statement_line: true)
        end
        Array(state['items']).each do |item|
          flow = @wizard.item_flow(item)
          next if flow.zero?

          what = { 'check' => bank['kind'] == 'credit_card' ? 'Uncleared charge' : 'Outstanding check',
                   'deposit' => bank['kind'] == 'credit_card' ? 'Uncleared payment' : 'Deposit in transit' }
                 .fetch(item['kind'], 'Uncleared item')
          memo = [what, item['reference'], item['payee'], item['date']].compact.join(' ')
          out << line(key, account_id, flow, memo, bank_qbo_id: row['qbo_account_id'], uncleared_item_id: item['id'])
        end
        out
      end

      def line(key, account_id, net, memo, **extra)
        { key: key, chart_of_account_id: account_id, debit_amount: net.positive? ? net.round(2) : BigDecimal('0'),
          credit_amount: net.negative? ? (-net).round(2) : BigDecimal('0'), memo: memo }.merge(extra)
      end

      def preview_resolver(row)
        choice = row['choice'] || {}
        case choice['action']
        when 'map'
          acct = @accounts[choice['chart_of_account_id'].to_i]
          return ["coa:#{acct.id}", "#{acct.account_number} #{acct.name}", acct.id] if acct
        when 'create'
          na = choice['new_account'] || {}
          return ["new:#{na['number']}", "#{na['number']} #{na['name']} (new)", nil]
        end
        ["unmapped:#{row['qbo_account_id']}", "Not mapped: #{row['qbo_name']}", nil]
      end
    end
  end
end
