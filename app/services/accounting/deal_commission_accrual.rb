# frozen_string_literal: true

module Accounting
  # Books a deal's commission once, when the deal is approved to the general
  # ledger, and keeps it in step with what the deal's commission payments add
  # up to afterwards (Tom, 2026-11-24: commission is booked when the deal is
  # approved).
  #
  # Before this, two places booked commission and neither knew about the
  # other. The closing entry added commission lines (6010 / 2020) only when
  # the deal already had a commission amount, which for companies paying at
  # accounting approval it never did, since payments are generated after the
  # closing entry. The commission approval action booked it again to other
  # accounts. On staging 3 deals carried $9,262.05 of commission twice.
  #
  # What is already booked is read from the books (lines on this deal, on an
  # expense account, whose memo starts with "Commission", in entries that are
  # not void), so entries made by the old closing entry or the old approval
  # action count too, and calling this any number of times posts only the
  # difference.
  #
  #   Debit  Sales Commissions (6010)   Credit  Accrued Expenses (2020)
  #
  # Paying commission posts nothing in DealerTide (payroll pays it), so 2020
  # holds what is owed until the dealer's payroll entry clears it.
  class DealCommissionAccrual
    EXPENSE_NUMBER = '6010'
    ACCRUED_NUMBER = '2020'
    MEMO = 'Commission accrual'

    def initialize(deal)
      @deal = deal
      @company = deal.company
    end

    # => { posted: amount } | { unchanged: true } | { skipped: reason } | { error: message }
    def sync!(user: nil)
      return { skipped: 'The deal is not approved to the books yet.' } unless @deal.gl_posted?

      owed = owed_amount
      booked = booked_amount
      difference = (owed - booked).round(2)
      return { unchanged: true } if difference.zero?

      expense = @company.chart_of_accounts.find_by(account_number: EXPENSE_NUMBER)
      accrued = @company.chart_of_accounts.find_by(account_number: ACCRUED_NUMBER)
      unless expense && accrued
        return { error: "Commission was not booked: accounts #{EXPENSE_NUMBER} and #{ACCRUED_NUMBER} must be in the chart of accounts." }
      end

      first = booked.zero? && !booked_before?
      je = post(difference, expense, accrued, first ? close_date : Date.current, first ? MEMO : "#{MEMO} change", user)
      # The close date can sit in a period closed since; book it today then.
      je ||= post(difference, expense, accrued, Date.current, first ? MEMO : "#{MEMO} change", user) if first && close_date != Date.current
      return { error: "Commission was not booked: #{@last_error || 'the entry could not be posted'}" } unless je

      @deal.update_columns(commission_posted: true, commission_posted_at: Time.current,
                           commission_journal_entry_id: @deal.commission_journal_entry_id || je.id)
      { posted: difference, journal_entry: je }
    end

    # What the deal's commission payments add up to. A deal that never had a
    # payment (no plan, or an amount typed at approval) uses its commission
    # amount; one whose payments were all cancelled or reversed owes nothing.
    def owed_amount
      all = CommissionPayment.where(deal_id: @deal.id, is_deleted: [false, nil])
      return (@deal.commission_amount || 0).to_d unless all.exists?

      all.where.not(status: %w[reversed cancelled]).sum(:amount).to_d
    end

    def booked_amount
      booked_lines.sum('journal_entry_lines.debit_amount - journal_entry_lines.credit_amount').to_d
    end

    private

    def booked_lines
      JournalEntryLine.joins(:journal_entry, :chart_of_account)
                      .where(deal_id: @deal.id, journal_entries: { company_id: @company.id, is_void: false })
                      .where(chart_of_accounts: { account_type: 'expense' })
                      .where('journal_entry_lines.memo ILIKE ?', 'Commission%')
    end

    def booked_before?
      booked_lines.exists?
    end

    def post(difference, expense, accrued, date, memo, user)
      service = ManualPostingService.new(@company)
      je = service.post_simple!(
        debit_account: difference.positive? ? expense : accrued,
        credit_account: difference.positive? ? accrued : expense,
        amount: difference.abs, memo: "#{memo}: #{label}", entry_date: date, source_entity: @deal,
        location_id: @deal.try(:location_id), department: department, contact_id: @deal.try(:contact_id),
        deal_id: @deal.id, vehicle_id: @deal.try(:vehicle_id), posted_by: user
      )
      @last_error = service.last_error_message
      je
    end

    # The closing entry's department, so commission sits with the sale.
    def department
      @deal.try(:deal_type).to_s.downcase.include?('used') ? 'used_sales' : 'new_sales'
    end

    def close_date
      (@deal.try(:closed_at) || @deal.try(:won_at) || @deal.try(:actual_close_date))&.to_date || Date.current
    end

    def label
      [@deal.try(:deal_number).presence, @deal.try(:name).presence || @deal.try(:title)].compact.join(' ').presence || "deal #{@deal.id}"
    end
  end
end
