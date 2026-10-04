# frozen_string_literal: true

# A QuickBooks switch carries a customer's leftover credit (a credit memo or
# unapplied payment with no open invoice to absorb it) over as a credit memo.
# accounting_import_id marks those so rollback removes them, like the open
# invoices and bills it carries over.
class AddAccountingImportToCreditMemos < ActiveRecord::Migration[8.0]
  def change
    add_reference :credit_memos, :accounting_import, null: true, index: { where: 'accounting_import_id IS NOT NULL' }
  end
end
