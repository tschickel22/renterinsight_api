# frozen_string_literal: true

# Rename credit_memos.qbo_id → quickbooks_id (and qbo_synced_at →
# quickbooks_synced_at) so the QB sync base class's generic save_quickbooks_id
# helper works without a per-handler override. No data to migrate — the
# table was created empty in the same PR that added it.
class AlignCreditMemoQbColumns < ActiveRecord::Migration[8.0]
  def change
    rename_column :credit_memos, :qbo_id,        :quickbooks_id
    rename_column :credit_memos, :qbo_synced_at, :quickbooks_synced_at
  end
end
