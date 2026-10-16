# frozen_string_literal: true

class Api::V1::DealPaymentsController < ApplicationController
  before_action :set_company_scope
  before_action :load_deal

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
