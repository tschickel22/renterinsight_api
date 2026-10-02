# frozen_string_literal: true

module McpTools
  # One journal entry with its lines, so the AI can check what a categorize,
  # a match or an Undo actually put in the books. Read only. Same plan
  # module and RBAC key (journal_entries read) as the app's journal entry
  # screen.
  class GetJournalEntry < Base
    tool_name 'get_journal_entry'
    title 'Get a journal entry'
    description 'One journal entry from the general ledger: date, entry number, memo, source (auto or manual, and ' \
                'the record that posted it, like BankTransaction:5), whether it is void, the entry that reversed it ' \
                '(reversed_by) or the one it reverses (reverses), and its lines with account number, account name, ' \
                'debit and credit. Look it up by id (journal_entry:16, as list_bank_transactions returns) or by ' \
                'entry_number (000002).'
    input_schema(
      properties: {
        id: { type: 'string', description: 'journal_entry:16' },
        entry_number: { type: 'string', description: 'The entry number shown in the app, like 000002' }
      }
    )
    read_only!

    def self.perform(ctx, id: nil, entry_number: nil)
      AccountingAccess.require!(ctx, 'journal_entries', 'read')
      raise UserError, 'Give id (journal_entry:16) or entry_number.' if id.blank? && entry_number.blank?

      ctx.row_limit(1)
      entries = visible(ctx).includes(:reversed_by, journal_entry_lines: :chart_of_account)
      je = if id.present?
             entries.find(AccountingAccess.parse_id(id, 'journal_entry'))
           else
             entries.find_by!(entry_number: entry_number.to_s.strip)
           end
      Base::Result.new(payload: AccountingAccess.journal_entry(ctx, je), count: 1)
    end

    # The company's entries. A location tier person sees an entry when any
    # line is at one of their locations, or no line is at any location
    # (company level entries), as unlocated records stay visible elsewhere.
    def self.visible(ctx)
      rel = ctx.company.journal_entries
      ids = ctx.location_ids
      return rel if ids.nil?
      return rel.none if ids.empty?

      lines = JournalEntryLine.where(journal_entry_id: rel.select(:id))
      located = lines.where.not(location_id: nil)
      rel.where(id: lines.where(location_id: ids).select(:journal_entry_id))
         .or(rel.where.not(id: located.select(:journal_entry_id)))
    end
  end
end
