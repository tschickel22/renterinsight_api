# frozen_string_literal: true

module McpTools
  # Marks a bank feed line as not to be booked: a duplicate import, or the
  # other side of a transfer already recorded. Posts nothing.
  class ExcludeBankTransaction < Base
    tool_name 'exclude_bank_transaction'
    title 'Exclude a bank transaction'
    description 'Mark one unmatched bank feed line as excluded so it is not booked: duplicates, or transfers between ' \
                "the dealer's own accounts already recorded on the other side. Posts no journal entry. A reason is " \
                'required. Confirm with the user first; real income or expenses must be categorized, not excluded.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'bank_txn:123' },
        reason: { type: 'string', description: 'Why, e.g. "Duplicate of the 9/14 line" or "Transfer to savings, booked there"' }
      },
      required: %w[id reason]
    )
    writes!(destructive: true)

    def self.perform(ctx, id:, reason:)
      AccountingAccess.require!(ctx, 'bank_accounts_accounting', 'update')
      raise UserError, 'A reason is required.' if reason.to_s.strip.blank?

      txn = AccountingAccess.bank_transactions(ctx).find(AccountingAccess.parse_id(id, 'bank_txn'))
      raise UserError, "That transaction is already #{txn.status}; only unmatched lines can be excluded here." unless txn.status == 'unmatched'

      before = { status: txn.status, excluded_reason: txn.excluded_reason }
      txn.exclude!(reason: reason.to_s.strip.first(500))
      ctx.record_change(action: 'updated', record: txn, before: before,
                        after: { status: txn.status, excluded_reason: txn.excluded_reason })
      Base::Result.new(payload: { excluded: AccountingAccess.bank_txn(ctx, txn) }, count: 1)
    end
  end
end
