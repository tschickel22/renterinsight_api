# frozen_string_literal: true

class Api::V1::DealPaymentsController < ApplicationController
  before_action :set_company_scope
  before_action :load_deal, except: [:open_balances]

  # POST /api/v1/deals/:id/record_payment
  # Money received from the customer on this deal. Before the deal has an
  # invoice it is a deposit, held in the deposits account until approval
  # applies it. An approved deal that never got its invoice gets one first.
  # Otherwise it is applied to the deal's invoice, filling draws in order.
  def record_payment
    return unless authorize_action!('accounting', 'create')

    service = DealPaymentService.new(@deal, user: current_user)
    entry = service.build_entry(params.permit(:amount, :payment_date, :payment_method, :bank_account_id, :reference_number, :memo))
    invoice = service.current_invoice
    if invoice && entry.amount > invoice.amount_due.to_d + 0.001
      return render(json: { error: 'Amount exceeds invoice balance due' }, status: :unprocessable_entity)
    end

    cr = service.record!(entry, invoice: invoice)
    invoice&.reload
    render json: {
      success: true,
      deposit: invoice.nil?,
      cash_receipt: {
        id: cr.id,
        receipt_number: cr.receipt_number,
        amount: cr.amount,
        receipt_date: cr.receipt_date,
        payment_method: cr.payment_method,
        reference_number: cr.reference_number,
        journal_entry_id: cr.journal_entry_id
      },
      invoice: invoice && {
        id: invoice.id,
        invoice_number: invoice.invoice_number,
        total: invoice.total,
        amount_paid: invoice.amount_paid,
        amount_due: invoice.amount_due,
        status: invoice.status,
        draw_schedule: invoice.draw_schedule
      }
    }
  rescue DealPaymentService::Error, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/v1/deals/open_balances?contact_id=&project_id=
  # Deals a customer payment could go toward, for Record Income.
  def open_balances
    return unless authorize_action!('accounting', 'read')

    render json: { deals: DealPaymentService.open_deals_for(@company, contact_id: params[:contact_id], project_id: params[:project_id]) }
  end

  # GET /api/v1/deals/:id/funding
  # What the deal has received: deposits still held, and its invoice.
  def funding
    return unless authorize_action!('accounting', 'read')

    service = DealPaymentService.new(@deal, user: current_user)
    invoice = @company.invoices.find_by(id: @deal.deal_invoice_id) if @deal.deal_invoice_id
    receipts = @company.cash_receipts.posted.not_deleted.where(deal_id: @deal.id).order(:receipt_date, :id)
    render json: {
      approved: @deal.gl_posted_at.present?,
      deposits_account: service.deposits_account&.slice(:id, :account_number, :name),
      deposits_held: service.held_deposits.sum(:amount_unapplied).to_f,
      receipts: receipts.map { |r| receipt_json(r) },
      invoice: invoice && invoice.slice(:id, :invoice_number, :total, :amount_paid, :amount_due, :status, :due_date, :draw_schedule)
    }
  end

  # POST /api/v1/deals/:id/create_invoice
  # The invoice a deal normally gets at approval, for an approved deal that
  # never got one (posted before auto-posted deals made theirs, or the step
  # failed). It bills AR the closing entry already booked, so it posts nothing.
  def create_invoice
    return unless authorize_action!('accounting', 'create')
    return render(json: { error: 'Approve the deal before invoicing it' }, status: :unprocessable_entity) unless @deal.gl_posted_at.present?

    invoice = DealInvoiceService.new(@deal, user: current_user).create_invoice!
    render json: { success: true, invoice: invoice.as_json(only: %i[id invoice_number total amount_due status due_date]) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/deals/:id/sync_invoice
  # Resets the deal invoice's total to what the books show owed (what
  # approval booked plus the sales tax it posted), spreading any difference
  # over the unpaid draws. For an invoice the Deal Funding books check flags.
  def sync_invoice
    return unless authorize_action!('accounting', 'update')

    invoice = @company.invoices.find_by(id: @deal.deal_invoice_id) if @deal.deal_invoice_id
    return render(json: { error: 'This deal has no invoice' }, status: :unprocessable_entity) unless invoice

    DealInvoiceService.new(@deal, user: current_user).sync_invoice!(invoice)
    invoice.reload.update_status_based_on_payments
    DealInvoiceService.refresh_draws!(invoice.reload)
    render json: { success: true, invoice: invoice.reload.slice(:id, :invoice_number, :total, :amount_paid, :amount_due, :status) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/deals/:id/post_invoice_payments  { bank_account_id }
  # Payments saved on the deal's invoice that never reached the ledger (the
  # invoice page used to save them without posting when "auto-post payments"
  # is off). Posts each into the bank account given: Dr bank, Cr AR.
  def post_invoice_payments
    return unless authorize_action!('accounting', 'create')

    invoice = @company.invoices.find_by(id: @deal.deal_invoice_id) if @deal.deal_invoice_id
    return render(json: { error: 'This deal has no invoice' }, status: :unprocessable_entity) unless invoice

    bank = @company.bank_accounts.find_by(id: params[:bank_account_id])
    return render(json: { error: 'Pick the bank account the money went into' }, status: :unprocessable_entity) unless bank&.chart_of_account

    posted_ids = @company.journal_entries.where(source_entity_type: 'Payment', is_void: false).select(:source_entity_id)
    payments = @company.payments.where(status: 'completed', id: PaymentApplication.where(applicable_type: 'Invoice', applicable_id: invoice.id).select(:payment_id))
                       .where.not(id: posted_ids)
    posted = payments.filter_map do |payment|
      payment.update_column(:bank_account_id, bank.id) if payment.bank_account_id.blank?
      Accounting::PaymentPostingService.new(payment.reload).post!(force: true)
    end
    if posted.size < payments.size
      return render json: { error: "#{payments.size - posted.size} of #{payments.size} payments could not be posted. Check that the default AR account is set." },
                    status: :unprocessable_entity
    end

    render json: { success: true, posted: posted.size, journal_entry_ids: posted.map(&:id) }
  end

  private

  def load_deal
    @deal = @company.deals.find_by(id: params[:id])
    render json: { error: 'Deal not found' }, status: :not_found unless @deal
  end

  def receipt_json(r)
    {
      id: r.id, receipt_number: r.receipt_number, receipt_date: r.receipt_date, amount: r.amount.to_f,
      amount_unapplied: r.amount_unapplied.to_f, payment_method: r.payment_method, reference_number: r.reference_number
    }
  end
end
