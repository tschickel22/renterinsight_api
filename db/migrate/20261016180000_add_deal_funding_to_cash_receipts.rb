# frozen_string_literal: true

# E78 steps 2 to 4: a receipt names the deal (and its project) it was taken
# for, deposits have a liability account to sit in until the deal is
# approved, and applying a deposit to the deal's invoice records the entry
# that moved it from deposits to receivables.
class AddDealFundingToCashReceipts < ActiveRecord::Migration[8.0]
  def up
    add_reference :cash_receipts, :deal, index: true, foreign_key: false
    add_reference :cash_receipts, :project, index: true, foreign_key: false
    add_reference :cash_receipt_applications, :journal_entry, index: true, foreign_key: false
    add_reference :accounting_settings, :customer_deposits_account, index: false, foreign_key: false

    # Receipts already applied to a deal's invoice belong to that deal.
    execute <<~SQL.squish
      UPDATE cash_receipts cr
      SET deal_id = d.id
      FROM cash_receipt_applications a
      JOIN deals d ON d.deal_invoice_id = a.invoice_id
      WHERE a.cash_receipt_id = cr.id AND cr.deal_id IS NULL AND d.company_id = cr.company_id
    SQL
    execute <<~SQL.squish
      UPDATE cash_receipts cr
      SET project_id = p.id
      FROM projects p
      WHERE p.deal_id = cr.deal_id AND p.company_id = cr.company_id
        AND COALESCE(p.is_deleted, FALSE) = FALSE AND cr.project_id IS NULL
    SQL
  end

  def down
    remove_reference :accounting_settings, :customer_deposits_account
    remove_reference :cash_receipt_applications, :journal_entry
    remove_reference :cash_receipts, :project
    remove_reference :cash_receipts, :deal
  end
end
