# frozen_string_literal: true

module Accounting
  module QboMigration
    # Undoes a posted migration: voids the opening entry and removes the open
    # invoices, bills, customer credit memos and opening reconciliations it
    # created. Allowed only
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

        # A few set queries, not several per item: one per invoice, bill and
        # memo took a posted switch's page 7.5 seconds and 8,781 queries on the
        # staging sandbox company (2026-11-11).
        inv_ids = invoices.map(&:id)
        paid_ids = Set.new
        if inv_ids.any?
          paid_ids.merge(PaymentApplication.where(applicable_type: 'Invoice', applicable_id: inv_ids).distinct.pluck(:applicable_id))
          paid_ids.merge(CreditMemoApplication.where(applicable_type: 'Invoice', applicable_id: inv_ids).distinct.pluck(:applicable_id))
          paid_ids.merge(CashReceiptApplication.where(invoice_id: inv_ids).distinct.pluck(:invoice_id))
        end
        inv = invoices.find { |i| paid_ids.include?(i.id) || i.amount_paid.to_d.positive? }
        return "Invoice #{inv.invoice_number} has a payment or credit applied since the switch" if inv

        paid_bills = bills.any? ? BillPayment.where(bill_id: bills.map(&:id)).distinct.pluck(:bill_id).to_set : Set.new
        bill = bills.find { |b| paid_bills.include?(b.id) }
        return "Bill #{bill.reference_number || bill.bill_number} has a payment applied since the switch" if bill

        applied = credit_memos.any? ? CreditMemoApplication.where(credit_memo_id: credit_memos.map(&:id)).distinct.pluck(:credit_memo_id).to_set : Set.new
        memo = credit_memos.find { |m| applied.include?(m.id) }
        return "Credit memo #{memo.credit_memo_number} has been applied since the switch" if memo

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
          # Dated the cutover, like the entry it reverses: dated today it left
          # the balances in the books as of the cutover and put the reversal,
          # P&L lines included, into the current month.
          entry&.void!(user, entry_date: entry.entry_date) unless entry&.is_void?

          reconciliations.each(&:destroy!)
          invoices.each(&:destroy!)
          bills.each(&:destroy!)
          credit_memos.each(&:destroy!)

          Array(@wizard.config.dig('posted', 'bank_gl_links')).each do |ba_id|
            @company.bank_accounts.find_by(id: ba_id)&.update_column(:chart_of_account_id, nil)
          end

          # Each matched bank feed was set to start the day after cutover; with
          # the switch undone it goes back to where it was, or September's
          # bank lines stay hidden for books that no longer hold them.
          @wizard.matched_banks.each do |bank|
            ba = @company.bank_accounts.find_by(id: bank.dig('match', 'bank_account_id'))
            next unless ba && ba.feed_start_date == @wizard.cutover_date + 1

            prior = bank.dig('match', 'previous_feed_start_date').presence
            ba.update_column(:feed_start_date, prior && Date.iso8601(prior))
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

      def credit_memos
        @credit_memos ||= @company.credit_memos.where(accounting_import_id: @import.id).to_a
      end

      def reconciliations
        @reconciliations ||= @company.bank_reconciliations.where(accounting_import_id: @import.id).includes(:bank_account).to_a
      end
    end
  end
end
