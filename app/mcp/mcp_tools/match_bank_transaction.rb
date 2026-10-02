# frozen_string_literal: true

module McpTools
  # Links a bank feed line to the journal entry that already booked it, as
  # the app's Match does. Posts nothing: the money is already in the books.
  class MatchBankTransaction < Base
    tool_name 'match_bank_transaction'
    title 'Match a bank transaction to its entry'
    description 'Link one unmatched bank feed line to the journal entry that already records it (the already_booked ' \
                'entry from list_bank_transactions). Posts nothing. Use this instead of categorizing whenever the ' \
                'money is already in the books, or it would be counted twice.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'bank_txn:123' },
        journal_entry_id: { type: 'string', description: 'journal_entry:456' }
      },
      required: %w[id journal_entry_id]
    )
    writes!(destructive: true)

    def self.perform(ctx, id:, journal_entry_id:)
      AccountingAccess.require!(ctx, 'bank_accounts_accounting', 'update')
      txn = AccountingAccess.bank_transactions(ctx).find(AccountingAccess.parse_id(id, 'bank_txn'))
      raise UserError, "That transaction is already #{txn.status}; only unmatched lines can be matched here." unless txn.status == 'unmatched'

      je = ctx.company.journal_entries.find(AccountingAccess.parse_id(journal_entry_id, 'journal_entry'))
      unless BankTransactionMatchingService.new(ctx.company).booked_entries(txn).include?(je)
        raise UserError, "Entry #{je.entry_number} does not record this line (same date, amount and side on this " \
                         "bank's GL account), or another line is already matched to it. Nothing was changed."
      end

      before = { status: txn.status, matched_journal_entry_id: nil, matched_by: nil }
      txn.match_to_journal_entry!(je, source: 'manual')
      ctx.record_change(action: 'updated', record: txn, before: before,
                        after: { status: txn.status, matched_journal_entry_id: je.id, matched_by: 'match' })
      Base::Result.new(payload: { matched: AccountingAccess.bank_txn(ctx, txn),
                                  journal_entry: { number: je.entry_number, date: je.entry_date&.iso8601 } }, count: 1)
    end
  end
end
