# frozen_string_literal: true

module McpTools
  # Accounting through the connector: read the books, and work the bank feed
  # one line at a time (categorize or exclude). Nothing here pays a bill,
  # sends an invoice, edits or voids a journal entry, or reconciles.
  module AccountingArea
    READ_TOOLS = [
      AccountingSummary, ListChartOfAccounts, ListBankTransactions, ListBills, ListInvoices
    ].freeze

    WRITE_TOOLS = [CategorizeBankTransaction, MatchBankTransaction, ExcludeBankTransaction].freeze

    PROMPTS = [McpPrompts::CategorizeBankFeed, McpPrompts::BillsDue, McpPrompts::MoneySnapshot].freeze

    module_function

    def handles?(record)
      record.is_a?(BankTransaction)
    end

    def label(record_type)
      'bank transaction' if record_type == 'BankTransaction'
    end

    # Neither tool creates a record.
    def undo_created(_change, _record)
      Undo.skipped('This kind of record cannot be undone automatically.')
    end

    # Categorized: void the journal entry it posted (a reversing entry, as
    # the app's Void does; posted entries are never deleted) and put the line
    # back to unmatched. Excluded: put it back to unmatched. Either way only
    # while the line is still exactly as the AI left it.
    def undo_updated(change, txn)
      return Undo.skipped('The transaction has been reconciled since. Undo the reconciliation in DealerTide first.') if txn.status == 'reconciled'

      after = change.after
      if after['matched_by'] == 'match'
        unless txn.status == 'matched' && txn.matched_journal_entry_id.to_s == after['matched_journal_entry_id'].to_s
          return Undo.skipped("Changed since: it is now #{txn.status}. Left as it is.")
        end

        txn.update!(status: 'unmatched', matched_journal_entry: nil, matched_at: nil, matched_by: nil)
        return Undo.done('Bank transaction unmatched from the entry. The entry itself was not touched.')
      end

      if after['status'] == 'excluded'
        return Undo.skipped("Changed since: it is now #{txn.status}. Left as it is.") unless txn.status == 'excluded'

        txn.update!(status: 'unmatched', excluded_reason: change.before['excluded_reason'])
        return Undo.done('Bank transaction put back to uncategorized.')
      end

      moved = %w[status category_account_id matched_journal_entry_id].find { |f| !Undo.same_value?(txn.public_send(f), after[f]) }
      return Undo.skipped("Changed since: #{moved.tr('_', ' ').sub(/ id\z/, '')} is different now. Left as it is.") if moved

      BankTransaction.transaction do
        je = txn.company.journal_entries.find_by(id: after['matched_journal_entry_id'])
        je.void!(Current.user) if je && !je.is_void?
        txn.unmatch!
        txn.update!(memo: change.before['memo'], contact_id: change.before['contact_id'])
      end
      Undo.done('Journal entry voided and the bank transaction put back to uncategorized.')
    end
  end
end
