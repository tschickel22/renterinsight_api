# frozen_string_literal: true

module McpTools
  # Categorizes one bank feed line exactly as the app's Categorize panel does
  # (create_je: true): the line is marked matched to the GL account and a
  # two-line journal entry is posted between the bank's GL account and that
  # account. One difference, deliberate: when the entry cannot be posted (no
  # GL account on the bank, or a closed period), the app still marks the line
  # categorized with nothing in the books; here nothing is saved and the AI is
  # told why.
  class CategorizeBankTransaction < Base
    tool_name 'categorize_bank_transaction'
    title 'Categorize a bank transaction'
    description 'Book one uncategorized bank feed line to a GL account (from list_chart_of_accounts), posting the ' \
                'journal entry the same way the app does. Only for lines still unmatched; confirm the account with ' \
                'the user first. Optional memo, and contact_id (contact:12) for who it was paid to or received from.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'bank_txn:123' },
        account_id: { type: 'string', description: 'gl_account:45' },
        memo: { type: 'string' },
        contact_id: { type: 'string', description: 'contact:12 (optional)' }
      },
      required: %w[id account_id]
    )
    writes!(destructive: true)

    def self.perform(ctx, id:, account_id:, memo: nil, contact_id: nil)
      AccountingAccess.require!(ctx, 'bank_accounts_accounting', 'update')
      txn = AccountingAccess.bank_transactions(ctx).find(AccountingAccess.parse_id(id, 'bank_txn'))
      unless txn.status == 'unmatched'
        raise UserError, "That transaction is already #{txn.status}#{" to #{txn.category_account.name}" if txn.category_account}. " \
                         'Only unmatched lines can be categorized here; change it in DealerTide if it is wrong.'
      end

      account = ctx.company.chart_of_accounts.find_by(id: AccountingAccess.parse_id(account_id, 'gl_account'))
      raise UserError, 'No GL account with that id. See list_chart_of_accounts.' unless account
      raise UserError, "#{account.name} is a header or inactive account and cannot be posted to." if account.is_header || !account.is_active

      bank_gl = txn.bank_account.chart_of_account
      unless bank_gl
        raise UserError, 'This bank account is not linked to a GL account, so no journal entry can be posted. ' \
                         'Link it under Accounting, Bank Accounts in DealerTide first.'
      end
      raise UserError, "That is this bank account's own GL account. Pick where the money came from or went to." if bank_gl.id == account.id

      contact = nil
      if contact_id.present?
        type, contact = Records.new(ctx).find(contact_id)
        raise UserError, 'contact_id must be a contact, like contact:12.' unless type == 'contact'
      end
      before = { status: txn.status, category_account_id: nil, matched_journal_entry_id: nil, memo: txn.memo, contact_id: txn.contact_id }

      BankTransaction.transaction do
        txn.categorize!(account: account, contact: contact, memo: memo.presence, create_je: true, source: 'manual')
        unless txn.reload.matched_journal_entry_id
          raise UserError, 'The journal entry could not be posted, most often because the transaction date is in a ' \
                           'closed period. Nothing was changed.'
        end
      end

      ctx.record_change(action: 'updated', record: txn, before: before,
                        after: { status: txn.status, category_account_id: account.id,
                                 matched_journal_entry_id: txn.matched_journal_entry_id, memo: txn.memo, contact_id: txn.contact_id })
      je = txn.matched_journal_entry
      Base::Result.new(payload: {
        categorized: AccountingAccess.bank_txn(ctx, txn),
        journal_entry: { number: je.entry_number, date: je.entry_date&.iso8601,
                         debit: AccountingAccess.gl_account(txn.deposit? ? bank_gl : account),
                         credit: AccountingAccess.gl_account(txn.deposit? ? account : bank_gl),
                         amount: AccountingAccess.money(txn.amount.abs) }
      }, count: 1)
    end
  end
end
