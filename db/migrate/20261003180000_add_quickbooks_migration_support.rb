# frozen_string_literal: true

# Switching a dealer from QuickBooks Online (backlog E62).
#
# feed_start_date: the bank feed ignores lines dated before it, so lines
# already inside the QuickBooks balances at cutover are not counted twice.
#
# accounting_import_id on invoices and bills marks open items carried over
# from QuickBooks. The opening entry already holds their AR and AP, so they
# never post to the ledger themselves, and rollback finds them by it.
#
# accounting_import_id on bank_reconciliations marks the opening
# reconciliation a migration creates at the cutover date, which carries the
# uncleared checks and deposits into the first real reconciliation.
class AddQuickbooksMigrationSupport < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_accounts, :feed_start_date, :date

    add_reference :invoices, :accounting_import, null: true, index: { where: 'accounting_import_id IS NOT NULL' }
    add_reference :bills, :accounting_import, null: true, index: { where: 'accounting_import_id IS NOT NULL' }
    add_reference :bank_reconciliations, :accounting_import, null: true,
                                                             index: { where: 'accounting_import_id IS NOT NULL' }

    add_column :bills, :quickbooks_id, :string
  end
end
