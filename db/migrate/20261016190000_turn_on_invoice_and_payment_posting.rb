# frozen_string_literal: true

# Invoices and payments post to the books for every company (Tom, 2026-10-16).
# Both were off for nearly everyone, and nothing else posted them, so invoice
# payments never reached the ledger. New companies already start with both on
# (AccountingSettings#set_auto_post_defaults).
#
# Forward only: nothing already saved is posted here. An older invoice is
# posted when a payment on it arrives (PaymentPostingService#receivable_on_books?).
class TurnOnInvoiceAndPaymentPosting < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL.squish
      UPDATE accounting_settings
      SET auto_post_invoices = TRUE, auto_post_payments = TRUE, updated_at = NOW()
      WHERE auto_post_invoices IS DISTINCT FROM TRUE OR auto_post_payments IS DISTINCT FROM TRUE
    SQL
  end

  def down
    # Which companies had them off is not kept; turn off by hand if needed.
  end
end
