# frozen_string_literal: true

class Api::V1::DealPaymentsController < ApplicationController
  before_action :set_company_scope
  before_action :load_deal

  # POST /api/v1/deals/:id/record_payment
  # Records a cash receipt applied to the deal's linked invoice and refreshes
  # invoice balance/draw schedule status.
  def record_payment
    return unless authorize_action!('accounting', 'create')

    invoice = @company.invoices.find_by(id: @deal.deal_invoice_id)
    return render(json: { error: 'Deal has no linked invoice' }, status: :unprocessable_entity) if invoice.nil?

    amount = params[:amount].to_d
    return render(json: { error: 'Amount must be greater than 0' }, status: :unprocessable_entity) if amount <= 0

    if amount > invoice.amount_due.to_d + 0.001
      return render(json: { error: 'Amount exceeds invoice balance due' }, status: :unprocessable_entity)
    end

    payment_date = parse_date(params[:payment_date]) || Date.current
    bank_account = @company.bank_accounts.find_by(id: params[:bank_account_id]) if params[:bank_account_id].present?

    cr = nil
    ActiveRecord::Base.transaction do
      cr = @company.cash_receipts.build(
        contact_id: invoice.contact_id,
        account_id: invoice.recipient_type == 'Account' ? invoice.recipient_id : nil,
        bank_account_id: bank_account&.id,
        receipt_date: payment_date,
        amount: amount,
        payment_method: params[:payment_method].presence || 'check',
        reference_number: params[:reference_number],
        memo: params[:memo].presence || "Payment for deal #{@deal.deal_number || @deal.id}",
        location_id: @deal.location_id || Current.location_id,
        customer_name: @deal.try(:customer_name)
      )
      cr.created_by_id = current_user&.id
      cr.cash_receipt_applications.build(invoice_id: invoice.id, amount_applied: amount)
      cr.amount_applied = amount
      cr.amount_unapplied = 0
      cr.save!

      update_draw_schedule_payment!(invoice, amount)
    end

    invoice.reload
    render json: {
      success: true,
      cash_receipt: {
        id: cr.id,
        receipt_number: cr.receipt_number,
        amount: cr.amount,
        receipt_date: cr.receipt_date,
        payment_method: cr.payment_method,
        reference_number: cr.reference_number,
        journal_entry_id: cr.journal_entry_id
      },
      invoice: {
        id: invoice.id,
        invoice_number: invoice.invoice_number,
        total: invoice.total,
        amount_paid: invoice.amount_paid,
        amount_due: invoice.amount_due,
        status: invoice.status,
        draw_schedule: invoice.draw_schedule
      }
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def load_deal
    @deal = @company.deals.find_by(id: params[:id])
    render json: { error: 'Deal not found' }, status: :not_found unless @deal
  end

  def parse_date(value)
    return nil if value.blank?
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Apply the payment against unpaid draws in order, marking them paid/partial.
  def update_draw_schedule_payment!(invoice, amount)
    schedule = invoice.draw_schedule
    return if schedule.blank? || !schedule.is_a?(Hash)

    draws = schedule['draws']
    return unless draws.is_a?(Array) && draws.any?

    remaining = amount.to_f
    draws.each do |draw|
      break if remaining <= 0
      next if draw['status'].to_s == 'paid'

      draw_amount = (draw['amount'] || 0).to_f
      paid = (draw['paid_amount'] || 0).to_f
      draw_balance = (draw_amount - paid).round(2)
      next if draw_balance <= 0

      apply = [remaining, draw_balance].min.round(2)
      draw['paid_amount'] = (paid + apply).round(2)
      draw['status'] = (draw['paid_amount'].to_f + 0.001 >= draw_amount) ? 'paid' : 'partial'
      remaining = (remaining - apply).round(2)
    end

    invoice.update_column(:draw_schedule, schedule)
  end
end
