# frozen_string_literal: true

# Which conversation (E96) a message belongs to. communications is a big table,
# so the index is built concurrently and the column is nullable with no default.
class AddConversationIdToCommunications < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :communications, :conversation_id, :bigint unless column_exists?(:communications, :conversation_id)
    add_index :communications, :conversation_id, algorithm: :concurrently, if_not_exists: true
  end
end
