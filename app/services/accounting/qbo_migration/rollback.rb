# frozen_string_literal: true

module Accounting
  module QboMigration
    # Undoes a posted migration: voids the opening entry and removes the open
    # invoices, bills and opening reconciliations it created. Allowed only
    # while nothing has built on it: no fiscal period from the cutover on is
    # closed, no imported invoice or bill has a payment or credit applied,
    # and no bank reconciliation has been completed after the opening one.
    #
    # Accounts, customers and vendors it created stay: they are harmless,
    # may already be in use, and a second run matches them by QuickBooks id.
    class Rollback
      def initialize(wizard)
        @wizard = wizard
        @import = wizard.import
        @company = wizard.company
      end

      # Why it cannot roll back, or nil when it can.
      def refusal
        return 'Only a posted switch can be rolled back' unless @import.status == 'posted'

        cutover = @wizard.cutover_date
        closed = @company.fiscal_periods.where(status: %w[closed locked]).where('end_date >= ?', cutover).order(:start_date).first
        if closed
          return "The books are closed for FY#{closed.fiscal_year} period #{closed.period_number}, after the cutover. " \
                 'Reopen it to roll back.'
        end

        invoices.each do |inv|
          paid = inv.payment_applications.exists? || inv.credit_memo_applications.exists? ||
                 CashReceiptApplication.where(invoice_id: inv.id).exists? || inv.amount_paid.to_d.positive?
          return "Invoice #{inv.invoice_number} has a payment or credit applied since the switch" if paid
        end
        bills.each do |bill|
          return "Bill #{bill.reference_number || bill.bill_number} has a payment applied since the switch" if bill.bill_payments.exists?
        end

        reconciliations.each do |rec|
          later = rec.bank_account.bank_reconciliations.where.not(id: rec.id).where('statement_date > ?', rec.statement_date)
          return "#{rec.bank_account.institution_name.presence || rec.bank_account.bank_name} has been reconciled since the switch" if later.exists?
        end
        nil
      end

      def run!(user)
        reason = refusal
        raise Error, reason if reason

        ActiveRecord::Base.transaction do
          entry = @company.journal_entries.find_by(id: @wizard.config.dig('posted', 'journal_entry_id'))
          entry&.void!(user) unless entry&.is_void?

          reconciliations.each(&:destroy!)
          invoices.each(&:destroy!)
          bills.each(&:destroy!)

          Array(@wizard.config.dig('posted', 'bank_gl_links')).each do |ba_id|
            @company.bank_accounts.find_by(id: ba_id)&.update_column(:chart_of_account_id, nil)
          end

          @wizard.config['rolled_back_at'] = Time.current.iso8601
          @wizard.config['rolled_back_by_id'] = user&.id
          @import.status = 'rolled_back'
          @wizard.save!
        end
      end

      private

      def invoices
        @invoices ||= @company.invoices.where(accounting_import_id: @import.id).to_a
      end

      def bills
        @bills ||= @company.bills.where(accounting_import_id: @import.id).to_a
      end

      def reconciliations
        @reconciliations ||= @company.bank_reconciliations.where(accounting_import_id: @import.id).includes(:bank_account).to_a
      end
    end
  end
end
