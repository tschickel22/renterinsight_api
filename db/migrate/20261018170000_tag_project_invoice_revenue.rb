# frozen_string_literal: true

# Invoices billed from a project (an installer billing its dealer for a linked
# job) now put their revenue on that project. Tag the revenue lines of the
# ones already posted, so the job's revenue sits beside its cost.
class TagProjectInvoiceRevenue < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE journal_entry_lines l
      SET project_id = i.source_id
      FROM journal_entries je
      JOIN invoices i ON je.source_entity_type = 'Invoice' AND je.source_entity_id = i.id
      JOIN chart_of_accounts a ON a.account_type = 'revenue'
      WHERE l.journal_entry_id = je.id
        AND l.chart_of_account_id = a.id
        AND i.source_type = 'Project'
        AND l.project_id IS NULL
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
