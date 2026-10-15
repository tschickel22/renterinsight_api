# frozen_string_literal: true

# E68 step 3: the job a cost belongs to travels with it onto the books, so a
# project's costs can be read from the ledger as well as from its cost lines.
class AddProjectToBillAndJournalLines < ActiveRecord::Migration[8.0]
  def change
    add_reference :bill_line_items, :project, foreign_key: false, index: true
    add_reference :journal_entry_lines, :project, foreign_key: false, index: true
  end
end
