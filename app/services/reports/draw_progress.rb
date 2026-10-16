# frozen_string_literal: true

module Reports
  # Where each draw on a deal invoice stands (E78). The draws are filled in
  # order with everything paid or credited on the invoice, the same order
  # Record Payment fills them, because not every way of paying updates the
  # stored schedule. Deal Funding and AR aging both read draws through this.
  module DrawProgress
    TOLERANCE = BigDecimal('0.01')

    module_function

    def call(invoice, applied = nil)
      schedule = invoice.draw_schedule
      draws = schedule.is_a?(Hash) ? schedule['draws'] : nil
      return [] unless draws.is_a?(Array)

      left = applied || (invoice.amount_paid.to_d + invoice.amount_credited.to_d)
      draws.sort_by { |d| d['position'].to_i }.map do |d|
        amount = d['amount'].to_d
        paid = [left, amount].min
        left -= paid
        balance = amount - paid
        {
          position: d['position'],
          description: d['description'],
          lender: lender_draw?(d),
          due_date: (Date.parse(d['due_date'].to_s) rescue nil),
          amount: amount,
          paid: paid,
          balance: balance,
          status: if balance <= TOLERANCE then 'paid'
                  elsif paid.positive? then 'partial'
                  else 'pending'
                  end
        }
      end
    end

    # The lender's funding on a financed deal's invoice (the approval screen's
    # Financed plan marks it; earlier ones are known by their description).
    def lender_draw?(draw)
      draw['kind'] == 'lender' || draw['description'].to_s.start_with?('Lender funding')
    end
  end
end
