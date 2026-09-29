# frozen_string_literal: true

# Accounting integrity guards.
#
# - gl_post_error / gl_post_failed_at: a document whose journal entry failed
#   to post used to leave only a log line, so the ledger quietly disagreed
#   with the invoice/bill. The reason now lives on the document.
# - tax_rate at 5 decimals: tax settings allow 8.875%, but invoices, their
#   items and quotes stored 8.88%, so the saved tax differed from what the
#   form showed. Widening keeps every existing value as-is.
class AccountingIntegrityColumns < ActiveRecord::Migration[8.0]
  RATE_TABLES = %i[invoices invoice_items quotes].freeze

  def up
    %i[invoices bills].each do |table|
      add_column table, :gl_post_error, :text
      add_column table, :gl_post_failed_at, :datetime
    end

    RATE_TABLES.each do |table|
      change_column table, :tax_rate, :decimal, precision: 8, scale: 5, default: '0.0'
    end
  end

  def down
    RATE_TABLES.each do |table|
      change_column table, :tax_rate, :decimal, precision: 5, scale: 2, default: '0.0'
    end

    %i[invoices bills].each do |table|
      remove_column table, :gl_post_failed_at
      remove_column table, :gl_post_error
    end
  end
end
