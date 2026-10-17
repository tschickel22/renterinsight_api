# frozen_string_literal: true

# New companies start with invoice and payment posting on (Tom, 2026-10-16).
# The 2026-10-16 migration turned it on for every company that existed then
# and relied on AccountingSettings#set_auto_post_defaults for new ones, but
# that only fills a nil, and the columns default to false, so a company
# created since started with both off. Found 2026-10-17 when a new installer
# company's invoice did not post.
class DefaultInvoiceAndPaymentPostingOn < ActiveRecord::Migration[8.0]
  def up
    change_column_default :accounting_settings, :auto_post_invoices, from: false, to: true
    change_column_default :accounting_settings, :auto_post_payments, from: false, to: true

    # Settings created since the turn-on with both still off were made by
    # that default, not by someone switching them off.
    execute <<~SQL.squish
      UPDATE accounting_settings
      SET auto_post_invoices = TRUE, auto_post_payments = TRUE, updated_at = NOW()
      WHERE created_at >= '2026-10-16'
        AND auto_post_invoices = FALSE AND auto_post_payments = FALSE
        AND updated_at < created_at + INTERVAL '1 minute'
    SQL
  end

  def down
    change_column_default :accounting_settings, :auto_post_invoices, from: true, to: false
    change_column_default :accounting_settings, :auto_post_payments, from: true, to: false
  end
end
