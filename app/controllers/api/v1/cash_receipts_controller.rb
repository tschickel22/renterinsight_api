# frozen_string_literal: true

class Api::V1::CashReceiptsController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('accounting', 'read')

    scope = @company.cash_receipts.not_deleted.includes(:account, :contact, :bank_account)
    scope = scope.for_current_location

    all_stats = {
      total: scope.count,
      posted: scope.posted.count,
      voided: scope.voided.count,
      total_received: scope.posted.sum(:amount),
      total_unapplied: scope.posted.sum(:amount_unapplied)
    }

    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?
    scope = scope.where('receipt_date >= ?', params[:date_from]) if params[:date_from].present?
    scope = scope.where('receipt_date <= ?', params[:date_to]) if params[:date_to].present?

    if params[:search].present?
      term = "%#{params[:search]}%"
      scope = scope.left_joins(:account)
        .where("cash_receipts.receipt_number ILIKE ? OR cash_receipts.customer_name ILIKE ? OR cash_receipts.reference_number ILIKE ? OR accounts.name ILIKE ?",
               term, term, term, term)
    end

    scope = scope.order(receipt_date: :desc, created_at: :desc)
    filtered_count = scope.count

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    scope = scope.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: scope.map { |cr| cash_receipt_json(cr) },
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: all_stats
      }
    }
  end

  def show
    return unless authorize_action!('accounting', 'read')

    cr = @company.cash_receipts.not_deleted.includes(
      :account, :contact, :bank_account,
      cash_receipt_applications: :invoice
    ).find(params[:id])

    render json: cash_receipt_detail_json(cr)
  end

  # GET /api/v1/cash_receipts/open_invoices?account_id=X
  def open_invoices
    return unless authorize_action!('accounting', 'read')

    invoices = @company.invoices
      .where(is_deleted: [false, nil])
      .where(status: %w[sent viewed partial overdue])
      .where('amount_due > 0')

    if params[:account_id].present?
      account_id = params[:account_id].to_i
      contact_ids = @company.contacts.where(account_id: account_id).pluck(:id)
      invoices = invoices.where(
        '(recipient_type = ? AND recipient_id = ?) OR (contact_id IN (?))',
        'Account', account_id, contact_ids
      )
    end

    invoices = invoices.where(contact_id: params[:contact_id]) if params[:contact_id].present?

    if params[:search].present?
      term = "%#{params[:search]}%"
      invoices = invoices.where("invoice_number ILIKE ? OR notes ILIKE ?", term, term)
    end

    invoices = invoices.order(due_date: :asc, created_at: :asc).limit(100)

    render json: invoices.map { |inv|
      account = inv.recipient_type == 'Account' ? inv.recipient : inv.contact&.account
      {
        id: inv.id,
        invoiceNumber: inv.invoice_number,
        invoiceDate: inv.invoice_date,
        dueDate: inv.due_date,
        totalAmount: inv.total,
        amountPaid: inv.amount_paid,
        balanceDue: inv.amount_due,
        status: inv.status,
        accountId: account&.id,
        accountName: account&.name,
        contactName: inv.contact ? "#{inv.contact.first_name} #{inv.contact.last_name}".strip : nil
      }
    }
  end

  def create
    return unless authorize_action!('accounting', 'create')

    cr = @company.cash_receipts.build(cash_receipt_params)
    cr.created_by_id = current_user&.id
    cr.location_id ||= Current.location_id if Current.location_id.present?

    if params[:applications].present?
      params[:applications].each do |app_params|
        cr.cash_receipt_applications.build(
          invoice_id: app_params[:invoice_id],
          amount_applied: app_params[:amount_applied]
        )
      end
    end

    applied_total = cr.cash_receipt_applications.sum { |a| a.amount_applied.to_d }
    cr.amount_applied = applied_total
    cr.amount_unapplied = cr.amount.to_d - applied_total

    if cr.save
      render json: cash_receipt_detail_json(cr.reload), status: :created
    else
      render json: { errors: cr.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def void
    return unless authorize_action!('accounting', 'update')

    cr = @company.cash_receipts.not_deleted.find(params[:id])

    if cr.status == CashReceipt::STATUS_VOIDED
      return render json: { error: 'Cash receipt is already voided' }, status: :unprocessable_entity
    end

    cr.void!
    render json: cash_receipt_detail_json(cr.reload)
  end

  def destroy
    return unless authorize_action!('accounting', 'delete')

    cr = @company.cash_receipts.not_deleted.find(params[:id])

    # Void first if posted (reverses JE and invoice balances)
    cr.void! if cr.status == CashReceipt::STATUS_POSTED

    # Soft delete
    cr.update!(is_deleted: true)
    render json: { message: 'Cash receipt deleted' }
  end

  private

  def cash_receipt_params
    params.require(:cash_receipt).permit(
      :account_id, :contact_id, :bank_account_id,
      :receipt_date, :amount, :payment_method,
      :reference_number, :memo, :customer_name, :location_id
    )
  end

  def cash_receipt_json(cr)
    {
      id: cr.id,
      receiptNumber: cr.receipt_number,
      receiptDate: cr.receipt_date,
      amount: cr.amount,
      amountApplied: cr.amount_applied,
      amountUnapplied: cr.amount_unapplied,
      paymentMethod: cr.payment_method,
      referenceNumber: cr.reference_number,
      memo: cr.memo,
      status: cr.status,
      customerName: cr.display_customer,
      accountId: cr.account_id,
      accountName: cr.account&.name,
      bankAccountName: cr.bank_account&.bank_name,
      journalEntryId: cr.journal_entry_id,
      createdAt: cr.created_at
    }
  end

  def cash_receipt_detail_json(cr)
    base = cash_receipt_json(cr)
    base[:applications] = cr.cash_receipt_applications.includes(:invoice).map { |app|
      {
        id: app.id,
        invoiceId: app.invoice_id,
        invoiceNumber: app.invoice&.invoice_number,
        invoiceTotalAmount: app.invoice&.total,
        invoiceBalanceDue: app.invoice&.amount_due,
        amountApplied: app.amount_applied
      }
    }
    base
  end
end
