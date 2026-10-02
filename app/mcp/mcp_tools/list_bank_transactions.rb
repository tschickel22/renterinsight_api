# frozen_string_literal: true

module McpTools
  # The bank feed, with a suggested account for each line still to be
  # categorized, learned from how this dealer booked the same payee before.
  class ListBankTransactions < ListTool
    tool_name 'list_bank_transactions'
    title 'List bank transactions'
    description 'Bank feed lines, newest first. Defaults to the ones still to be categorized (status unmatched). ' \
                'Each unmatched line carries suggested_account (the GL account this dealer used most for the same ' \
                'payee before, with how often and a confidence) or suggested_action exclude (when that payee was ' \
                'excluded before), any bank rule that matches, already_booked (an entry already in the books for ' \
                'exactly this line: match it with match_bank_transaction, never categorize it), and looks_like (transfer, ' \
                'card payment, floor plan, check, fee, deposit). Suggestions are hints: confirm with the user before ' \
                'categorize_bank_transaction. Filter by bank_account_id, dates, direction or a description search.'
    input_schema(
      properties: {
        status: { type: 'string', enum: %w[unmatched matched excluded reconciled any] },
        bank_account_id: { type: 'integer' },
        start_date: { type: 'string', description: 'ISO date, e.g. 2026-09-01' },
        end_date: { type: 'string', description: 'ISO date' },
        direction: { type: 'string', enum: %w[deposit withdrawal any] },
        query: { type: 'string', description: 'Description, reference or memo contains' },
        min_amount: { type: 'number', description: 'Absolute amount at least this much' },
        include_journal_matches: { type: 'boolean',
                                   description: 'Also look for an existing journal entry each line could match (slower; use on small lists)' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: 'unmatched', bank_account_id: nil, start_date: nil, end_date: nil, direction: 'any',
                     query: nil, min_amount: nil, include_journal_matches: false, limit: 20)
      AccountingAccess.require!(ctx, 'bank_accounts_accounting', 'read')
      all = AccountingAccess.bank_transactions(ctx)
      rel = all.includes(:bank_account, :category_account, :matched_journal_entry)
      rel = rel.where(status: status) unless status.to_s.in?(['', 'any'])
      rel = rel.where(bank_account_id: bank_account_id) if bank_account_id.present?
      from = parse_date(start_date, 'start_date')
      to = parse_date(end_date, 'end_date')
      rel = rel.where(transaction_date: from..) if from
      rel = rel.where(transaction_date: ..to) if to
      rel = rel.where('bank_transactions.amount > 0') if direction == 'deposit'
      rel = rel.where('bank_transactions.amount < 0') if direction == 'withdrawal'
      rel = rel.where('ABS(bank_transactions.amount) >= ?', min_amount.to_d) if min_amount.present?
      if query.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
        rel = rel.where('bank_transactions.description ILIKE :t OR bank_transactions.reference_number ILIKE :t OR ' \
                        'bank_transactions.memo ILIKE :t', t: term)
      end

      rows = rel.order(transaction_date: :desc, id: :desc).limit(ctx.row_limit(limit)).to_a
      unmatched = rows.select { |t| t.status == 'unmatched' }
      suggestions = suggestions_for(ctx, all, unmatched)
      matcher = BankTransactionMatchingService.new(ctx.company) if include_journal_matches && unmatched.size <= 15

      booking = BankTransactionMatchingService.new(ctx.company)
      items = rows.map do |txn|
        row = AccountingAccess.bank_txn(ctx, txn)
        next row unless suggestions[txn.id]

        row = row.merge(suggestions[txn.id])
        booked = booking.booked_entries(txn)
        if booked.any?
          # Already in the books: match it, never categorize it.
          row[:already_booked] = booked.first(3).map do |je|
            { entry_id: "journal_entry:#{je.id}", entry_number: je.entry_number, date: je.entry_date&.iso8601,
              memo: je.memo.to_s.first(120) }
          end
          row.delete(:suggested_account)
          row[:suggested_action] = 'match'
        end
        row[:journal_matches] = journal_matches(matcher, txn) if matcher
        row
      end

      counts = all.group(:status).count
      Base::Result.new(payload: {
        count: items.size, items: items,
        totals: { unmatched: counts['unmatched'].to_i, matched: counts['matched'].to_i,
                  excluded: counts['excluded'].to_i, reconciled: counts['reconciled'].to_i,
                  oldest_unmatched: all.where(status: 'unmatched').minimum(:transaction_date)&.iso8601 },
        bank_accounts: AccountingAccess.bank_accounts(ctx).map do |ba|
          { id: ba.id, name: AccountingAccess.bank_account_label(ba), gl_account: AccountingAccess.gl_account(ba.chart_of_account) }.compact
        end
      }, count: items.size)
    end

    def self.suggestions_for(ctx, all, unmatched)
      return {} if unmatched.empty?

      history = BankPayee.history(all)
      rules = ctx.company.bank_rules.active.by_priority.to_a
      accounts = ctx.company.chart_of_accounts.where(is_active: true, is_header: false).index_by(&:id)
      unmatched.to_h do |txn|
        [txn.id, BankPayee.suggest(txn, history, accounts, rules.select { |r| r.bank_account_id.nil? || r.bank_account_id == txn.bank_account_id })]
      end
    end

    def self.journal_matches(matcher, txn)
      matcher.suggest_matches(txn, limit: 3).map do |m|
        { entry_number: m[:entry_number], date: m[:entry_date]&.iso8601, memo: m[:memo].to_s.first(120),
          amount: AccountingAccess.money(m[:line_amount]), score: m[:score] }
      end
    rescue StandardError => e
      Rails.logger.warn("[McpTools] journal match suggestions failed: #{e.class}: #{e.message}")
      []
    end
  end
end
