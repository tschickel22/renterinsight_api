# frozen_string_literal: true

module Deals
  # Deleting a deal is permanent, so it is refused while the deal carries money
  # or paperwork that has to be undone first (posted books, payments, commissions,
  # a signed or out-for-signature agreement, a loan). Everything else that points
  # at the deal is cleaned up here so the delete cannot fail on a foreign key.
  #
  #   check = Deals::Deletion.new(deal)
  #   check.blockers   # => ["It has 2 payments recorded. Void them first.", ...]
  #   check.destroy!   # => raises Deals::Deletion::Blocked when blockers exist
  class Deletion
    class Blocked < StandardError
      attr_reader :blockers

      def initialize(blockers)
        @blockers = blockers
        super(blockers.join(' '))
      end
    end

    def initialize(deal)
      @deal = deal
    end

    def blockers
      reasons = []

      entries = JournalEntryLine.joins(:journal_entry)
                                .where(deal_id: @deal.id)
                                .where(journal_entries: { is_void: [false, nil] })
                                .distinct.count(:journal_entry_id)
      reasons << "It has #{plural(entries, 'accounting entry', 'accounting entries')} posted. Void or reverse #{them(entries)} first." if entries.positive?

      receipts = CashReceipt.where(deal_id: @deal.id, is_deleted: false, voided_at: nil)
                            .where.not(status: 'voided').count
      reasons << "It has #{plural(receipts, 'payment')} recorded. Void #{them(receipts)} first." if receipts.positive?

      invoices = @deal.invoices.where(is_deleted: [false, nil]).where.not(status: %w[draft cancelled]).count
      reasons << "It has #{plural(invoices, 'invoice')} past draft. Cancel #{them(invoices)} first." if invoices.positive?

      bank = BankTransaction.where(deal_id: @deal.id).count
      reasons << "#{plural(bank, 'bank feed line is', 'bank feed lines are')} applied to it. Unapply #{them(bank)} first." if bank.positive?

      commissions = Commission.where(deal_id: @deal.id).where.not(status: 'cancelled').count +
                    @deal.commission_payments.where.not(status: %w[cancelled reversed]).count
      reasons << "It has #{plural(commissions, 'commission')} on it. Cancel #{them(commissions)} first." if commissions.positive?

      signed = Agreement.where(deal_id: @deal.id, is_deleted: false)
                        .where(status: [Agreement::STATUS_COMPLETED, *Agreement::ACTIVE_STATUSES]).count
      reasons << "It has #{plural(signed, 'agreement')} signed or out for signature. Void #{them(signed)} first." if signed.positive?

      loans = Loan.where(financed_entity_type: 'Deal', financed_entity_id: @deal.id, is_deleted: false)
                  .where.not(status: 'cancelled').count
      reasons << "It has #{plural(loans, 'loan')} against it. Cancel #{them(loans)} first." if loans.positive?

      reasons
    end

    def destroy!
      reasons = blockers
      raise Blocked, reasons if reasons.any?

      Deal.transaction do
        # Rows whose foreign key would otherwise stop the delete.
        DealDeskShare.where(deal_id: @deal.id).delete_all
        Commission.where(deal_id: @deal.id).delete_all # only cancelled ones are left
        CatalogOptionRequest.where(deal_id: @deal.id).update_all(deal_id: nil)
        CatalogPriceRequest.where(deal_id: @deal.id).update_all(deal_id: nil)
        PurchaseOrderChangeOrder.where(deal_id: @deal.id).update_all(deal_id: nil)
        Agreement.where(deal_id: @deal.id).update_all(deal_id: nil)
        JournalEntryLine.where(deal_id: @deal.id).update_all(deal_id: nil) # voided entries only
        # Draft or cancelled invoices made for this deal go with it.
        @deal.invoices.where(status: %w[draft cancelled]).update_all(is_deleted: true)
        @deal.update_column(:deal_invoice_id, nil) if @deal.deal_invoice_id
        @deal.destroy!
      end
    end

    private

    def them(count) = count == 1 ? 'it' : 'them'

    def plural(count, one, many = "#{one}s")
      "#{count} #{count == 1 ? one : many}"
    end
  end
end
