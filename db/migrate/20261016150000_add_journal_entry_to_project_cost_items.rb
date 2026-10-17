# frozen_string_literal: true

# A Record Expense or manual journal entry line tagged to a project becomes
# that project's job cost, the way a bill does. The cost line remembers the
# entry so an edit or void keeps it in step.
class AddJournalEntryToProjectCostItems < ActiveRecord::Migration[8.0]
  def change
    add_reference :project_cost_items, :journal_entry, foreign_key: false, index: true
  end
end
