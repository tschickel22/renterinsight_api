# frozen_string_literal: true

module Reports
  class CashFlowForecastService
    HORIZON_DAYS = 90

    def initialize(company)
      @company = company
    end

    # Generate a forward-looking cash flow forecast.
    # Returns current cash, weekly projections, and itemised upcoming obligations.
    #
    # @param horizon_days [Integer] how far out to project (default 90)
    # @param location_id [Integer, nil] optional location filter
    def generate(horizon_days: HORIZON_DAYS, location_id: nil)
      today = Date.current
      horizon_end = today + horizon_days.days

      cash_now = current_cash_position(location_id)

      upcoming_bills          = fetch_upcoming_bills(today, horizon_end, location_id)
      upcoming_receivables    = fetch_upcoming_receivables(today, horizon_end, location_id)
      upcoming_recurring      = project_recurring_bills(today, horizon_end, location_id)
      upcoming_commissions    = fetch_pending_commissions(today, horizon_end, location_id)
      upcoming_loans          = fetch_upcoming_loan_payments(today, horizon_end)
      upcoming_draws          = fetch_upcoming_draw_schedule_inflows(today, horizon_end, location_id)
      upcoming_deal_ar        = fetch_deal_ar_inflows(today, horizon_end, location_id)

      all_receivables = upcoming_receivables + upcoming_draws + upcoming_deal_ar

      # Build weekly buckets
      weeks = build_weekly_projection(
        today, horizon_end, cash_now,
        upcoming_bills, all_receivables, upcoming_recurring,
        upcoming_commissions, upcoming_loans
      )

      # Cash runway: first week where projected balance goes negative
      runway_weeks = weeks.index { |w| w[:projected_balance] < 0 }
      runway_days  = runway_weeks ? (runway_weeks * 7) : nil

      {
        generated_at: Time.current.iso8601,
        horizon_days: horizon_days,
        current_cash: cash_now.round(2),
        weekly_projection: weeks,
        summary: {
          total_expected_inflows: all_receivables.sum { |r| r[:amount] }.round(2),
          total_expected_outflows: (
            upcoming_bills.sum { |b| b[:amount] } +
            upcoming_recurring.sum { |r| r[:amount] } +
            upcoming_commissions.sum { |c| c[:amount] } +
            upcoming_loans.sum { |l| l[:amount] }
          ).round(2),
          projected_ending_cash: weeks.last&.dig(:projected_balance)&.round(2) || cash_now.round(2),
          cash_runway_days: runway_days,
        },
        upcoming_bills: upcoming_bills.first(20),
        upcoming_receivables: upcoming_receivables.first(20),
        upcoming_draws: upcoming_draws.first(20),
        upcoming_deal_ar: upcoming_deal_ar.first(20),
        upcoming_recurring: upcoming_recurring.first(20),
        upcoming_commissions: upcoming_commissions.first(10),
        upcoming_loans: upcoming_loans.first(10),
      }
    end

    private

    # =========================================================================
    # CURRENT CASH
    # =========================================================================

    def current_cash_position(location_id)
      scope = @company.bank_accounts.where(is_active: true, is_deleted: false)
      scope = scope.where(location_id: location_id) if location_id.present?
      scope.sum(:current_balance).to_f
    end

    # =========================================================================
    # UPCOMING BILLS (AP)
    # =========================================================================

    def fetch_upcoming_bills(from_date, to_date, location_id)
      scope = @company.bills
        .where(status: %w[draft pending partially_paid])
        .where(is_deleted: false)
        .where('balance_due > 0')
        .where(due_date: from_date..to_date)
        .order(:due_date)

      scope = scope.where(location_id: location_id) if location_id.present?

      scope.map do |bill|
        {
          id: bill.id,
          type: 'bill',
          description: bill.vendor_name.presence || "Bill ##{bill.bill_number}",
          reference: bill.bill_number,
          amount: bill.balance_due.to_f,
          due_date: bill.due_date&.iso8601,
        }
      end
    end

    # =========================================================================
    # UPCOMING RECEIVABLES (AR)
    # =========================================================================

    def fetch_upcoming_receivables(from_date, to_date, location_id)
      scope = @company.invoices
        .where(status: %w[sent overdue partially_paid])
        .where(is_deleted: false)
        .where('amount_due > 0')
        .where(due_date: from_date..to_date)
        .order(:due_date)

      scope = scope.where(location_id: location_id) if location_id.present?

      scope.map do |inv|
        {
          id: inv.id,
          type: 'invoice',
          description: "Invoice ##{inv.invoice_number}",
          reference: inv.invoice_number,
          amount: inv.amount_due.to_f,
          due_date: inv.due_date&.iso8601,
        }
      end
    end

    # =========================================================================
    # DRAW SCHEDULE INFLOWS (unpaid draws on deal-backed invoices)
    # =========================================================================

    def fetch_upcoming_draw_schedule_inflows(from_date, to_date, location_id)
      scope = @company.invoices
        .where(is_deleted: [false, nil])
        .where.not(status: %w[paid cancelled draft])
        .where("draw_schedule IS NOT NULL AND draw_schedule::text <> '{}'")

      scope = scope.where(location_id: location_id) if location_id.present?

      items = []
      scope.find_each do |inv|
        next unless inv.draw_schedule.is_a?(Hash)
        draws = inv.draw_schedule['draws'] || inv.draw_schedule[:draws]
        next unless draws.is_a?(Array)

        draws.each_with_index do |draw, idx|
          status = draw['status'].to_s
          next if status == 'paid'

          amount = (draw['amount'] || 0).to_f
          paid_amount = (draw['paid_amount'] || 0).to_f
          remaining = (amount - paid_amount).round(2)
          next if remaining <= 0

          due_str = draw['due_date'] || draw[:due_date]
          next if due_str.blank?
          due = parse_iso_date(due_str)
          next unless due && due.between?(from_date, to_date)

          label = draw['description'].presence || "Draw #{idx + 1}"
          items << {
            id: "#{inv.id}-d#{idx}",
            type: 'draw_schedule',
            description: "Invoice ##{inv.invoice_number} — #{label}",
            reference: inv.invoice_number,
            amount: remaining,
            due_date: due.iso8601,
          }
        end
      end

      items.sort_by { |i| i[:due_date] }
    end

    # =========================================================================
    # DEAL AR INFLOWS (deals posted to GL but with no invoice yet)
    # =========================================================================

    def fetch_deal_ar_inflows(from_date, to_date, location_id)
      scope = @company.deals
        .where(gl_posted: true)
        .where(deal_invoice_id: nil)
        .where('selling_price > 0')

      scope = scope.where(location_id: location_id) if location_id.present?

      items = []
      scope.find_each do |deal|
        close = deal.try(:actual_close_date) || deal.try(:won_at)&.to_date || deal.try(:gl_posted_at)&.to_date
        next unless close

        total = deal.try(:selling_price).to_f
        next unless total > 0

        # Spread over 90 days from close date in 30-day buckets.
        per_bucket = (total / 3.0).round(2)
        [0, 30, 60].each_with_index do |offset, idx|
          due = close + offset.days
          next unless due.between?(from_date, to_date)

          amount = idx == 2 ? (total - per_bucket * 2).round(2) : per_bucket
          items << {
            id: "deal-#{deal.id}-#{idx}",
            type: 'deal_ar',
            description: "Deal #{deal.try(:deal_number) || deal.id} (estimated)",
            reference: deal.try(:deal_number) || "D-#{deal.id}",
            amount: amount,
            due_date: due.iso8601,
          }
        end
      end

      items.sort_by { |i| i[:due_date] }
    end

    def parse_iso_date(value)
      return value if value.is_a?(Date)
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # =========================================================================
    # RECURRING BILLS (projected future occurrences)
    # =========================================================================

    def project_recurring_bills(from_date, to_date, location_id)
      scope = @company.recurring_bills.where(is_active: true)
      scope = scope.where(location_id: location_id) if location_id.present?

      projections = []

      scope.find_each do |rb|
        next_date = rb.next_due_date
        next unless next_date

        while next_date <= to_date
          if next_date >= from_date
            projections << {
              id: rb.id,
              type: 'recurring_bill',
              description: rb.name,
              reference: rb.invoice_number_pattern,
              amount: rb.amount.to_f,
              due_date: next_date.iso8601,
            }
          end
          next_date = advance_date(next_date, rb.frequency)
          break if next_date.nil?
        end
      end

      projections.sort_by { |p| p[:due_date] }
    end

    # =========================================================================
    # PENDING COMMISSIONS (approved but unpaid)
    # =========================================================================

    def fetch_pending_commissions(from_date, to_date, location_id)
      scope = @company.commission_payments
        .where(status: %w[approved])
        .where(is_deleted: false)
        .where('amount > 0')

      scope = scope.where(location_id: location_id) if location_id.present?

      scope.order(:approved_at).map do |cp|
        {
          id: cp.id,
          type: 'commission',
          description: "Commission #{cp.payment_number}",
          reference: cp.payment_number,
          amount: cp.amount.to_f,
          due_date: (cp.approved_at&.to_date || from_date).iso8601,
        }
      end
    end

    # =========================================================================
    # UPCOMING LOAN PAYMENTS
    # =========================================================================

    def fetch_upcoming_loan_payments(from_date, to_date)
      scope = @company.loans
        .where(status: 'active', is_deleted: false)
        .where.not(next_payment_date: nil)
        .where(next_payment_date: from_date..to_date)
        .order(:next_payment_date)

      scope.map do |loan|
        {
          id: loan.id,
          type: 'loan_payment',
          description: "Loan #{loan.loan_number}",
          reference: loan.loan_number,
          amount: loan.regular_payment_amount.to_f,
          due_date: loan.next_payment_date&.iso8601,
        }
      end
    end

    # =========================================================================
    # WEEKLY PROJECTION BUILDER
    # =========================================================================

    def build_weekly_projection(from_date, to_date, starting_cash, bills, receivables, recurring, commissions, loans)
      all_outflows = bills + recurring + commissions + loans
      all_inflows  = receivables

      weeks = []
      current = from_date
      balance = starting_cash

      while current <= to_date
        week_end = [current + 6.days, to_date].min

        week_inflows = all_inflows
          .select { |i| i[:due_date] && Date.parse(i[:due_date]).between?(current, week_end) }
          .sum { |i| i[:amount] }

        week_outflows = all_outflows
          .select { |o| o[:due_date] && Date.parse(o[:due_date]).between?(current, week_end) }
          .sum { |o| o[:amount] }

        net = week_inflows - week_outflows
        balance += net

        weeks << {
          week_start: current.iso8601,
          week_end: week_end.iso8601,
          expected_inflows: week_inflows.round(2),
          expected_outflows: week_outflows.round(2),
          net_change: net.round(2),
          projected_balance: balance.round(2),
        }

        current = week_end + 1.day
      end

      weeks
    end

    # =========================================================================
    # DATE HELPERS
    # =========================================================================

    def advance_date(date, frequency)
      case frequency&.downcase
      when 'weekly'       then date + 1.week
      when 'biweekly'     then date + 2.weeks
      when 'monthly'      then date + 1.month
      when 'quarterly'    then date + 3.months
      when 'semi_annual', 'semi-annual', 'semiannual' then date + 6.months
      when 'annual', 'yearly' then date + 1.year
      else nil
      end
    end
  end
end
