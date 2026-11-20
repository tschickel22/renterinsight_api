# frozen_string_literal: true

module Accounting
  module QboMigration
    # Going live from a trial: the invoices the dealer made in DealerTide
    # during the trial and dated on or before the cutover. QuickBooks owns
    # that period, so going live voids their entries (Wizard#settlement) and
    # brings QuickBooks' own open invoices over. Left alone, a sale entered in
    # both systems came over twice and one entered only here dropped out of
    # the books. So the dealer answers for each one:
    #
    #   same    it is QuickBooks invoice X. X is not brought over again: this
    #           invoice takes its QuickBooks id and, when it owes more than X
    #           did at the cutover, an off-books credit for the difference.
    #   paid    it was paid in full in QuickBooks. An off-books credit closes it.
    #   keep    it is not in QuickBooks. Its entries, its payments' and its
    #           deal's stay in DealerTide's books instead of being voided.
    #   cancel  not a real sale. The invoice is cancelled.
    #
    # Answers live in import_config['trial_invoices'] as
    # { invoice_id => { 'answer', 'qbo_external_id' } }. The off-books credits
    # are credit memos carrying the switch's accounting_import_id, so a
    # rollback removes them; credit memos never post to the ledger.
    class TrialInvoices
      ANSWERS = %w[same paid keep cancel].freeze

      def initialize(wizard)
        @wizard = wizard
        @company = wizard.company
      end

      def d(value) = Wizard.d(value)

      # Only a go-live switch from a trial has them.
      def applies?
        !@wizard.trial? && @wizard.config['trial_started_at'].present?
      end

      def cutover = @wizard.cutover_date

      def since
        Time.zone.parse(@wizard.config['trial_started_at'])
      end

      def invoices
        return [] unless applies?

        @invoices ||= @company.invoices.where(is_deleted: [false, nil]).where.not(status: 'cancelled')
                              .where(accounting_import_id: nil).where('invoices.created_at >= ?', since)
                              .where('COALESCE(invoices.invoice_date, CAST(invoices.created_at AS date)) <= ?', cutover)
                              .includes(:contact).order(:invoice_date, :id).to_a
      end

      def answers
        @wizard.config['trial_invoices'] || {}
      end

      def answer_for(invoice)
        answers[invoice.id.to_s]
      end

      def open_qbo_invoices
        @open_qbo_invoices ||= Array(@wizard.config['open_invoices'])
      end

      # What the invoice still owed at the end of the cutover day: its total
      # less payments, receipts and credits dated on or before then. Later
      # ones stay in DealerTide's books and keep reducing it after going live.
      def due_at_cutover(invoice)
        paid = PaymentApplication.joins(:payment)
                                 .where(applicable_type: 'Invoice', applicable_id: invoice.id)
                                 .where(payments: { status: 'completed' })
                                 .where('payments.payment_date <= ?', cutover).sum('payment_applications.amount')
        received = CashReceiptApplication.joins(:cash_receipt).where(invoice_id: invoice.id)
                                         .where(cash_receipts: { status: CashReceipt::STATUS_POSTED, is_deleted: [false, nil] })
                                         .where('cash_receipts.receipt_date <= ?', cutover).sum(:amount_applied)
        credited = CreditMemoApplication.joins(:credit_memo)
                                        .where(applicable_type: 'Invoice', applicable_id: invoice.id)
                                        .where(credit_memos: { status: %w[issued partial applied], is_deleted: [false, nil] })
                                        .where('credit_memos.memo_date <= ?', cutover).sum('credit_memo_applications.amount')
        (invoice.total.to_d - paid.to_d - received.to_d - credited.to_d).round(2)
      end

      # contact id => QuickBooks customer id, from the contact's own id (a
      # trial links it) or the customer step's match.
      def customer_ids
        @customer_ids ||= begin
          map = {}
          @wizard.list_rows('customers').each do |r|
            map[r.dig(:match, :id)] = r[:external_id] if r[:status] == 'link' && r.dig(:match, :type) == 'contact'
          end
          ids = invoices.map(&:contact_id).compact.uniq
          @company.contacts.where(id: ids).where.not(quickbooks_id: [nil, '']).pluck(:id, :quickbooks_id)
                  .each { |id, qid| map[id] = qid.to_s }
          map
        end
      end

      # QuickBooks invoice ids already answered as "same", invoice id => qbo id.
      def claimed
        answers.select { |_id, a| a['answer'] == 'same' && a['qbo_external_id'].present? }
               .transform_values { |a| a['qbo_external_id'].to_s }
      end

      # The QuickBooks open invoice this one most likely is: same customer and
      # same number, or same customer and the same amount owing at the cutover.
      # Never one already answered for another invoice, or suggested for an
      # earlier one.
      def suggestions
        @suggestions ||= begin
          taken = claimed.values.to_set
          out = {}
          invoices.each do |inv|
            next if answer_for(inv)

            customer = customer_ids[inv.contact_id]
            due = due_at_cutover(inv)
            pool = open_qbo_invoices.reject { |q| taken.include?(q['external_id'].to_s) }
            same_customer = customer ? pool.select { |q| q['customer_external_id'].to_s == customer.to_s } : []
            by_number = same_customer.find { |q| q['invoice_number'].present? && q['invoice_number'].to_s == inv.invoice_number.to_s }
            by_amount = same_customer.select { |q| d(q['balance']).round(2) == due }
            pick, reason =
              if by_number
                [by_number, 'Same customer and invoice number']
              elsif by_amount.size == 1
                [by_amount.first, 'Same customer and amount owing']
              end
            next unless pick

            taken << pick['external_id'].to_s
            out[inv.id.to_s] = { 'answer' => 'same', 'qbo_external_id' => pick['external_id'].to_s, 'reason' => reason }
          end
          out
        end
      end

      def qbo_by_id
        @qbo_by_id ||= open_qbo_invoices.index_by { |q| q['external_id'].to_s }
      end

      # carry: what QuickBooks' invoice owes at the cutover after customer
      # credits from QuickBooks are applied to it, oldest invoice first, the
      # way Poster#save_invoices! applies them.
      def qbo_carry
        @qbo_carry ||= begin
          carry = open_qbo_invoices.sort_by { |i| [i['date'].to_s, i['external_id'].to_s] }
                                   .to_h { |i| [i['external_id'].to_s, d(i['balance']).round(2)] }
          @wizard.customer_credits.each do |credit|
            left = d(credit['balance']).round(2)
            open_qbo_invoices.select { |i| i['customer_external_id'] == credit['customer_external_id'] }
                             .sort_by { |i| [i['date'].to_s, i['external_id'].to_s] }.each do |inv|
              break if left.zero?

              id = inv['external_id'].to_s
              take = [left, carry[id]].min
              carry[id] -= take
              left -= take
            end
          end
          carry
        end
      end

      # Problems with one answer, worded for the person.
      def problems(inv, ans)
        return [] unless ans

        out = []
        if %w[same paid].include?(ans['answer']) && inv.status == 'draft'
          out << (inv.awaiting_deal_approval? ? 'Approve the deal first, so its entries are settled with the rest' : 'Finalize it first, so its entry is settled with the rest')
        end
        if ans['answer'] == 'same'
          q = qbo_by_id[ans['qbo_external_id'].to_s]
          if q.nil?
            out << 'That QuickBooks invoice is not open at the cutover any more. Pick another answer'
          elsif claimed.count { |_id, qid| qid == ans['qbo_external_id'].to_s } > 1
            out << "QuickBooks invoice #{q['invoice_number'] || q['external_id']} is picked for more than one invoice"
          end
        end
        out
      end

      def difference(inv, ans)
        return nil unless ans && ans['answer'] == 'same'
        return nil unless (carry = qbo_carry[ans['qbo_external_id'].to_s])

        due_at_cutover(inv) - carry
      end

      def rows
        invoices.map do |inv|
          ans = answer_for(inv)
          diff = difference(inv, ans)
          {
            invoice_id: inv.id, invoice_number: inv.invoice_number, invoice_date: inv.invoice_date&.iso8601,
            customer: inv.contact&.display_name, contact_id: inv.contact_id, deal_id: inv.deal_id || (inv.source_type == 'Deal' ? inv.source_id : nil),
            status: inv.status, awaiting_deal_approval: inv.awaiting_deal_approval?,
            total: Wizard.money(inv.total), amount_due: Wizard.money(inv.amount_due), due_at_cutover: Wizard.money(due_at_cutover(inv)),
            answer: ans&.dig('answer'), qbo_external_id: ans&.dig('qbo_external_id'),
            suggestion: suggestions[inv.id.to_s],
            # Positive: this invoice owed more than QuickBooks' at the cutover;
            # an off-books credit takes it down. Negative: it owed less, and
            # receivables here are short by that much.
            difference: diff && Wizard.money(diff),
            problems: problems(inv, ans)
          }
        end
      end

      def json
        list = rows
        used = claimed
        {
          applies: applies?,
          cutover_date: cutover&.iso8601,
          invoices: list,
          quickbooks_invoices: open_qbo_invoices.map do |q|
            id = q['external_id'].to_s
            { external_id: id, invoice_number: q['invoice_number'], date: q['date'], customer: q['customer_name'],
              customer_external_id: q['customer_external_id'], total: Wizard.money(q['total']),
              balance: Wizard.money(q['balance']), carry: Wizard.money(qbo_carry[id]),
              used_by_invoice_id: used.key(id)&.to_i }
          end,
          counts: { total: list.size, answered: list.count { |r| r[:answer] },
                    suggested: list.count { |r| r[:answer].nil? && r[:suggestion] },
                    problems: list.sum { |r| r[:problems].size } },
          posted: !@wizard.draft?
        }
      end

      def step
        return nil unless applies?

        list = invoices
        answered = list.count { |i| answer_for(i) }
        bad = list.sum { |i| problems(i, answer_for(i)).size }
        { done: answered == list.size && bad.zero?, total: list.size, answered: answered, problems: bad }
      end

      def blocker_messages
        return [] unless applies?

        out = []
        waiting = invoices.count { |i| answer_for(i).nil? }
        if waiting.positive?
          out << "#{waiting} #{waiting == 1 ? 'invoice' : 'invoices'} made during the trial and dated on or before the cutover " \
                 "#{waiting == 1 ? 'needs' : 'need'} an answer: in QuickBooks too, paid there, not in QuickBooks, or cancel"
        end
        invoices.each do |inv|
          problems(inv, answer_for(inv)).each { |p| out << "Invoice #{inv.invoice_number}: #{p}" }
        end
        out
      end

      # Preview notes: an invoice matched to a QuickBooks one that owed more.
      def differences
        invoices.filter_map do |inv|
          diff = difference(inv, answer_for(inv))
          next unless diff&.negative?

          "Invoice #{inv.invoice_number} owed #{@wizard.fmt(-diff)} less at the cutover than its QuickBooks invoice. " \
            'It keeps its own balance, so receivables here are that much below QuickBooks. Record the difference on the invoice if the customer owes it.'
        end
      end

      # answers: [{ invoice_id, answer, qbo_external_id }]. answer 'auto'
      # forgets one; 'accept_suggestions' without an invoice_id takes every
      # suggestion still unanswered.
      def update!(list)
        @wizard.ensure_draft!
        raise Error, 'Only going live from a trial has invoices to answer' unless applies?

        saved = (@wizard.config['trial_invoices'] ||= {})
        ids = invoices.map { |i| i.id.to_s }.to_set
        Array(list).each do |a|
          a = a.to_h.stringify_keys
          if a['invoice_id'].blank? && a['answer'].to_s == 'accept_suggestions'
            suggestions.each { |id, s| saved[id] ||= s.slice('answer', 'qbo_external_id') }
            reset!
            next
          end

          id = a['invoice_id'].to_s
          raise Error, "Invoice #{id} is not one made during the trial" unless ids.include?(id)

          answer = a['answer'].to_s
          if answer == 'auto'
            saved.delete(id)
          elsif answer == 'same'
            qid = a['qbo_external_id'].to_s
            raise Error, 'Pick the QuickBooks invoice it is' if qid.blank?
            raise Error, 'That QuickBooks invoice is not open at the cutover' unless qbo_by_id.key?(qid)

            other = claimed.find { |inv_id, q| q == qid && inv_id != id }
            if other
              number = invoices.find { |i| i.id.to_s == other[0] }&.invoice_number
              raise Error, "That QuickBooks invoice is already picked for invoice #{number}"
            end
            saved[id] = { 'answer' => 'same', 'qbo_external_id' => qid }
          elsif ANSWERS.include?(answer)
            saved[id] = { 'answer' => answer }
          else
            raise Error, 'Pick an answer'
          end
          reset!
        end
        @wizard.config.delete('preview_viewed_at')
        @wizard.save!
      end

      # Entries going live must leave alone: those of invoices kept in
      # DealerTide, their payments' and receipts', and their deal's.
      def kept_entry_ids
        kept = invoices.select { |i| answer_for(i)&.dig('answer') == 'keep' }
        return [] if kept.empty?

        inv_ids = kept.map(&:id)
        deal_ids = kept.filter_map { |i| i.deal_id || (i.source_type == 'Deal' ? i.source_id : nil) }.uniq
        payment_ids = PaymentApplication.where(applicable_type: 'Invoice', applicable_id: inv_ids).distinct.pluck(:payment_id)
        receipt_ids = CashReceiptApplication.where(invoice_id: inv_ids).distinct.pluck(:cash_receipt_id)
        sources = [['Invoice', inv_ids], ['Deal', deal_ids], ['Payment', payment_ids], ['CashReceipt', receipt_ids]]
        sources.reject { |_t, ids| ids.empty? }.flat_map do |type, ids|
          @company.journal_entries.where(source_entity_type: type, source_entity_id: ids).pluck(:id)
        end
      end

      # ── Posting (Poster) ─────────────────────────────────────────

      # Invoices answered "same", by QuickBooks id. save_invoices! hands these
      # QuickBooks invoices to #adopt! instead of creating them again.
      def by_qbo_id
        claimed.to_h { |inv_id, qid| [qid, invoices.find { |i| i.id.to_s == inv_id }] }.compact
      end

      # This invoice is QuickBooks' invoice qbo (carry owing at the cutover).
      def adopt!(invoice, qbo, carry, import:, user:, location_id:)
        invoice.update_columns(quickbooks_id: qbo['external_id'].to_s, quickbooks_synced_at: Time.current)
        over = [due_at_cutover(invoice) - carry, invoice.amount_due.to_d].min.round(2)
        memo = nil
        if over.positive?
          memo = off_books_credit!(invoice, over, import: import, user: user, location_id: location_id,
                                                  reason: "Matched to QuickBooks invoice #{qbo['invoice_number'] || qbo['external_id']}, " \
                                                          "which owed #{@wizard.fmt(carry)} at the #{cutover.iso8601} cutover")
        end
        { 'invoice_id' => invoice.id, 'credit_memo_id' => memo&.id }
      end

      # paid and cancel, after the switch's own invoices are in.
      def settle!(import:, user:, location_id:)
        out = { 'adopted' => [], 'paid' => [], 'cancelled' => [] }
        invoices.each do |inv|
          case answer_for(inv)&.dig('answer')
          when 'paid'
            due = inv.reload.amount_due.to_d.round(2)
            memo = if due.positive?
                     off_books_credit!(inv, due, import: import, user: user, location_id: location_id,
                                                 reason: "Paid in QuickBooks before the #{cutover.iso8601} cutover")
                   end
            out['paid'] << { 'invoice_id' => inv.id, 'credit_memo_id' => memo&.id }
          when 'cancel'
            out['cancelled'] << { 'invoice_id' => inv.id, 'status_before' => inv.status }
            inv.update!(status: 'cancelled')
          end
        end
        out
      end

      private

      def reset!
        @suggestions = nil
      end

      def off_books_credit!(invoice, amount, import:, user:, location_id:, reason:)
        memo = @company.credit_memos.build(
          location_id: invoice.location_id || location_id, contact_id: invoice.contact_id, memo_date: cutover,
          reason: reason, notes: 'Made by the QuickBooks switch when going live. It does not post to the books: ' \
                                 'QuickBooks held this invoice up to the cutover.',
          accounting_import_id: import.id, created_by_id: user&.id
        )
        memo.credit_memo_items.build(description: reason, quantity: 1, rate: amount, taxable: false, skip_tax: true)
        memo.save!
        memo.issue!
        memo.apply_to!(invoice, amount: amount, created_by: user)
        invoice.update_status_based_on_payments
        memo
      end
    end
  end
end
