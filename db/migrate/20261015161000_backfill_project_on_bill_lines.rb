# frozen_string_literal: true

# Bills already tied to a project (contractor portal invoices and cost-line
# drafts from E68 step 2) predate project on lines. Give their lines the
# bill's project, and their ledger debits the project and its deal, so the
# reports see them. Only tags change; no amounts move and closed (locked)
# entries are left alone.
class BackfillProjectOnBillLines < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL.squish
      UPDATE bill_line_items SET project_id = bills.project_id
      FROM bills
      WHERE bill_line_items.bill_id = bills.id AND bills.project_id IS NOT NULL AND bill_line_items.project_id IS NULL
    SQL

    # A bill's debits are its line items in order; tag them only where the
    # entry still lines up one debit per line on the same accounts.
    select_rows(<<~SQL.squish).each do |(bill_id, je_id)|
      SELECT bills.id, bills.journal_entry_id FROM bills
      JOIN journal_entries je ON je.id = bills.journal_entry_id
      WHERE bills.project_id IS NOT NULL AND je.is_void = FALSE AND COALESCE(je.locked, FALSE) = FALSE
    SQL
      lines = select_rows("SELECT id, chart_of_account_id, project_id FROM bill_line_items WHERE bill_id = #{bill_id.to_i} ORDER BY id")
      debits = select_rows("SELECT id, chart_of_account_id FROM journal_entry_lines WHERE journal_entry_id = #{je_id.to_i} AND debit_amount > 0 ORDER BY id")
      next unless lines.size == debits.size && lines.zip(debits).all? { |l, d| l[1] == d[1] }

      lines.zip(debits).each do |(_, _, project_id), (debit_id, _)|
        deal = project_id.to_i == 0 ? 'NULL' : (select_value("SELECT deal_id FROM projects WHERE id = #{project_id.to_i}") || 'NULL')
        execute "UPDATE journal_entry_lines SET project_id = #{project_id ? project_id.to_i : 'NULL'}, deal_id = COALESCE(deal_id, #{deal}) WHERE id = #{debit_id.to_i}"
      end
    end
  end

  def down
    # Tags only; nothing to undo safely.
  end
end
