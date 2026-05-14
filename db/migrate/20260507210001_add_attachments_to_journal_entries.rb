# frozen_string_literal: true

class AddAttachmentsToJournalEntries < ActiveRecord::Migration[8.0]
  def change
    add_column :journal_entries, :attachments, :jsonb, default: []
  end
end
