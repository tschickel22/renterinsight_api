# frozen_string_literal: true

# Records money received from a customer on a deal (E78).
#
# Before the deal has an invoice, the receipt is a deposit: it posts Dr bank /
# Cr the deposits account, tagged to the deal, and waits there. When the
# deal's invoice is made (approval, auto-post or Create invoice) the deposit is
# applied to it (DealInvoiceService#apply_deposits!).
#
# Once there is an invoice, the receipt is applied to it, filling draws in
# order. Anything over what the invoice still owes stays on the receipt as a
# deposit for the deal rather than being refused, so an overpayment is never
# lost or booked to the wrong place.
class DealPaymentService
  METHODS = CashReceipt::PAYMENT_METHODS

  class Error < StandardError; end

  Entry = Struct.new(:amount, :date, :payment_method, :bank_account, :reference_number, :memo, keyword_init: true)

  def initialize(deal, user: nil)
    @deal = deal
    @company = deal.company
    @user = user
  end

  # Checks one receipt's fields and returns an Entry, or raises Error with a
  # message the screen can show. Used up front by the approval screen so a bad
  # row stops the approval before anything posts.
  def build_entry(attrs)
    attrs = attrs.to_h.with_indifferent_access
    amount = BigDecimal(attrs[:amount].to_s) rescue BigDecimal('0')
    raise Error, 'Each payment needs an amount greater than 0' unless amount.positive?

    date = attrs[:payment_date].presence || attrs[:date].presence
    date = date ? (Date.parse(date.to_s) rescue nil) : Date.current
    raise Error, 'Each payment needs a valid date' unless date

    method = attrs[:payment_method].presence || 'check'
    raise Error, "Payment method must be one of: #{METHODS.join(', ')}" unless METHODS.include?(method)

    bank = @company.bank_accounts.find_by(id: attrs[:bank_account_id]) if attrs[:bank_account_id].present?
    raise Error, 'Pick the bank account the money went into' unless bank

    Entry.new(amount: amount.round(2), date: date, payment_method: method, bank_account: bank,
              reference_number: attrs[:reference_number].presence, memo: attrs[:memo].presence)
  end

  # Records the entry on the deal. Returns the cash receipt.
  def record!(entry, invoice: current_invoice)
    unless invoice || deposits_account
      raise Error, 'Set the customer deposits account in Accounting Settings before taking a deposit'
    end

    applied = invoice ? [entry.amount, invoice.amount_due.to_d].min : 0.to_d
    receipt = nil
    ActiveRecord::Base.transaction do
      receipt = @company.cash_receipts.build(
        deal: @deal,
        contact_id: invoice&.contact_id || @deal.contact_id,
        account_id: invoice&.recipient_type == 'Account' ? invoice.recipient_id : @deal.account_id,
        bank_account: entry.bank_account,
        receipt_date: entry.date,
        amount: entry.amount,
        payment_method: entry.payment_method,
        reference_number: entry.reference_number,
        memo: entry.memo || default_memo(invoice),
        location_id: @deal.location_id || Current.location_id,
        customer_name: @deal.try(:customer_name),
        status: CashReceipt::STATUS_POSTED
      )
      receipt.created_by_id = @user&.id
      receipt.cash_receipt_applications.build(invoice_id: invoice.id, amount_applied: applied) if applied.positive?
      receipt.amount_applied = applied
      receipt.amount_unapplied = entry.amount - applied
      receipt.save!
    end
    DealInvoiceService.refresh_draws!(invoice.reload) if invoice
    receipt
  end

  # The deal's invoice, made now if the deal is approved but never got one.
  def current_invoice
    invoice = @company.invoices.find_by(id: @deal.deal_invoice_id) if @deal.deal_invoice_id
    return invoice if invoice
    return nil unless @deal.gl_posted_at.present?

    DealInvoiceService.new(@deal, user: @user).create_invoice!
  end

  # Money held on the deal: deposits not yet applied to an invoice.
  def held_deposits
    @company.cash_receipts.posted.not_deleted.where(deal_id: @deal.id).where('amount_unapplied > 0').order(:receipt_date, :id)
  end

  def deposits_account
    AccountingSettings.for_company(@company).deposits_account
  end

  private

  def default_memo(invoice)
    label = @deal.deal_number || @deal.id
    invoice ? "Payment for deal #{label}" : "Deposit for deal #{label}"
  end
end
