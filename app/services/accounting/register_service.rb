# frozen_string_literal: true

module Accounting
  # One account's register, as QuickBooks shows it: every posted line in a
  # date range, newest first, with the balance after each line, the payee,
  # the other side of the entry, and whether the line has cleared the bank.
  #
  # Money is in the account's own terms. For a bank (debit normal) a debit is
  # money in and the balance is what it holds; for a card or other credit
  # normal account a credit is a charge and the balance is what is owed. The
  # same rules as the General Ledger report (JournalEntry.in_ledger,
  # AccountBalanceService), so the two always agree.
  class RegisterService
    MAX_ROWS = 2000

    def initialize(company)
      @company = company
    end

    def call(account:, start_date:, end_date:, location_id: nil)
      lines = JournalEntryLine
              .joins(:journal_entry)
              .merge(JournalEntry.in_ledger)
              .where(chart_of_account_id: account.id, journal_entries: { company_id: @company.id })
              .where(journal_entries: { entry_date: start_date..end_date })
              .includes(:contact, journal_entry: [:source_entity, { journal_entry_lines: :chart_of_account }])
              .order('journal_entries.entry_date ASC, journal_entries.id ASC, journal_entry_lines.id ASC')
      lines = lines.where(location_id: location_id) if location_id

      total = lines.count
      truncated = total > MAX_ROWS
      # Keep the newest rows; the running balance still starts from the true
      # opening balance, so skipped older rows are folded into it.
      skipped = truncated ? lines.limit(total - MAX_ROWS) : nil
      kept = truncated ? lines.offset(total - MAX_ROWS).to_a : lines.to_a

      balances = AccountBalanceService.new(@company)
      opening = balances.balance_as_of(account, start_date - 1.day, location_id: location_id)
      opening += net_of(account, skipped) if skipped

      status = clear_status(kept.map(&:id), kept.map(&:journal_entry_id))
      running = opening
      rows = kept.map do |line|
        change = signed(account, line.debit_amount, line.credit_amount)
        running += change
        row_json(line, account, running, status)
      end

      {
        account: {
          id: account.id, account_number: account.account_number, name: account.name,
          account_type: account.account_type, normal_balance: account.normal_balance
        },
        bank_account: bank_json(account),
        period: { start_date: start_date, end_date: end_date },
        opening_balance: opening.to_f,
        closing_balance: running.to_f,
        rows: rows.reverse,
        total_rows: total,
        truncated: truncated
      }
    end

    private

    def signed(account, debit, credit)
      account.normal_balance == 'debit' ? debit - credit : credit - debit
    end

    def net_of(account, scope)
      ids = scope.pluck('journal_entry_lines.id')
      sums = JournalEntryLine.where(id: ids).pick(Arel.sql('COALESCE(SUM(debit_amount),0)'), Arel.sql('COALESCE(SUM(credit_amount),0)'))
      signed(account, sums[0], sums[1])
    end

    # reconciled: in a finished reconciliation. cleared: ticked in one still
    # open, or matched to a line from the bank feed. Otherwise not yet seen
    # at the bank.
    def clear_status(line_ids, entry_ids)
      items = BankReconciliationItem.joins(:bank_reconciliation)
                                    .where(journal_entry_line_id: line_ids, cleared: true)
                                    .pluck(:journal_entry_line_id, 'bank_reconciliations.status')
      out = {}
      items.each do |line_id, rec_status|
        out[line_id] = rec_status == 'completed' ? 'reconciled' : (out[line_id] || 'cleared')
      end
      matched = @company.bank_transactions.where(matched_journal_entry_id: entry_ids).distinct.pluck(:matched_journal_entry_id).to_set
      { lines: out, matched_entries: matched }
    end

    def row_json(line, account, running, status)
      entry = line.journal_entry
      others = entry.journal_entry_lines.reject { |l| l.id == line.id }
      other_accounts = others.map(&:chart_of_account).compact.uniq
      money_in, money_out = in_out(account, line)
      {
        line_id: line.id,
        journal_entry_id: entry.id,
        date: entry.entry_date,
        entry_number: entry.entry_number,
        source_type: entry.source_entity_type,
        payee: payee(line, entry),
        account: if other_accounts.size == 1
                   { id: other_accounts.first.id, name: label(other_accounts.first) }
                 elsif other_accounts.size > 1
                   { id: nil, name: 'Split' }
                 end,
        memo: line.memo.presence || entry.memo,
        money_in: money_in,
        money_out: money_out,
        balance: running.round(2).to_f,
        status: status[:lines][line.id] || (status[:matched_entries].include?(entry.id) ? 'cleared' : nil),
        location_id: line.location_id
      }
    end

    # A debit is money in for a bank and a payment for a card; a credit is
    # money out of a bank and a charge on a card. The screen names them.
    def in_out(_account, line)
      debit = line.debit_amount.to_d
      credit = line.credit_amount.to_d
      [debit.zero? ? nil : debit.to_f, credit.zero? ? nil : credit.to_f]
    end

    def payee(line, entry)
      return line.contact.display_name if line.contact
      src = entry.source_entity
      return nil unless src

      vendor = src.try(:vendor)
      contact = src.try(:contact)
      vendor&.display_name.presence || contact&.display_name.presence ||
        (src.is_a?(BankTransaction) ? src.description.to_s.truncate(60) : nil)
    end

    def label(coa)
      [coa.account_number, coa.name].compact_blank.join(' ')
    end

    def bank_json(account)
      ba = @company.bank_accounts.where(is_deleted: [false, nil]).find_by(chart_of_account_id: account.id)
      return nil unless ba

      { id: ba.id, name: ba.bank_name, account_type: ba.account_type, mask: ba.account_mask || ba.display_last_four,
        bank_balance: ba.bank_balance&.to_f, bank_balance_as_of: ba.bank_balance_as_of, stripe_connected: ba.stripe_connected? }
    end
  end
end
