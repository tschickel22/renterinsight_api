# frozen_string_literal: true

# Lightweight quick-entry endpoint that creates a balanced 2-line journal entry
# for a simple expense or income transaction without requiring the user to think
# in debits/credits.
class Api::V1::RecordTransactionsController < ApplicationController
  before_action :set_company_scope

  # POST /api/v1/record_transactions
  #
  # Params:
  #   type: 'expense' | 'income'      (required)
  #   date: ISO date                  (defaults to today)
  #   amount: decimal                 (required, > 0)
  #   category_account_id: ID of expense or revenue GL account
  #   payment_account_id: ID of cash/bank GL account
  #   vendor_name / customer_name: optional
  #   contact_id: optional (the customer on income, picked from contacts)
  #   project_id: optional (the job it was spent on or received for; its deal
  #               rides along, and its deal's customer when no contact is given)
  #   memo: optional
  #   location_id: optional (defaults to Current.location_id)
  #   reference_number: optional (check #, receipt #, etc.)
  def create
    return unless authorize_action!('journal_entries', 'create')

    type = params[:type].to_s
    unless %w[expense income].include?(type)
      return render json: { error: "type must be 'expense' or 'income'" }, status: :bad_request
    end

    amount = BigDecimal(params[:amount].to_s) rescue BigDecimal('0')
    if amount <= 0
      return render json: { error: 'Amount must be greater than zero' }, status: :bad_request
    end

    category_account = @company.chart_of_accounts.find_by(id: params[:category_account_id])
    payment_account = @company.chart_of_accounts.find_by(id: params[:payment_account_id])

    applying = type == 'income' && params[:apply_to_deal_id].present?
    unless (category_account || applying) && payment_account
      return render json: { error: 'Both category_account_id and payment_account_id are required' }, status: :bad_request
    end

    location_id = params[:location_id].presence || Current.location_id

    # Money a customer paid toward a deal is not new revenue: approval already
    # booked the sale. Record it on the deal instead (a payment on its
    # invoice, or a deposit if the deal is not approved yet).
    if type == 'income' && params[:apply_to_deal_id].present?
      return record_deal_payment(amount, payment_account)
    end

    project = nil
    if params[:project_id].present?
      project = @company.projects.not_deleted.find_by(id: params[:project_id])
      return render json: { error: 'Project not found' }, status: :unprocessable_entity unless project
    end
    contact = nil
    if params[:contact_id].present?
      contact = @company.contacts.find_by(id: params[:contact_id])
      return render json: { error: 'Customer not found' }, status: :unprocessable_entity unless contact
    end
    picked_contact = contact
    contact ||= project&.deal&.contact if type == 'income'
    tags = { contact_id: contact&.id, project_id: project&.id, deal_id: project&.deal_id }

    # Name the customer the way the project and its deal show them. A deal can
    # carry a typed customer name that differs from its linked contact.
    party_name = if type == 'expense'
                   params[:vendor_name]
                 else
                   params[:customer_name].presence || picked_contact&.full_name ||
                     project&.customer_display_name.presence&.then { |n| n == 'Unknown' ? nil : n } ||
                     contact&.full_name
                 end
    memo_prefix = type == 'expense' ? 'Expense' : 'Income'

    # Build memo: always include party name for list display
    user_memo = params[:memo].presence
    if party_name.present? && user_memo.present?
      memo = "#{party_name} — #{user_memo}"
    elsif party_name.present?
      memo = "#{memo_prefix}: #{party_name}"
    elsif user_memo.present?
      memo = user_memo
    else
      memo = "#{memo_prefix}: #{category_account.name}"
    end
    ref = params[:reference_number].presence

    je = @company.journal_entries.build(
      entry_date: params[:date].presence || Date.current,
      memo: ref ? "#{memo} (Ref #{ref})" : memo,
      source_type: 'quick_entry',
      posted_by: current_user
    )

    if type == 'expense'
      # DEBIT expense, CREDIT cash/bank
      je.journal_entry_lines.build(
        chart_of_account: category_account,
        debit_amount: amount,
        credit_amount: 0,
        memo: memo,
        location_id: location_id,
        **tags
      )
      je.journal_entry_lines.build(
        chart_of_account: payment_account,
        debit_amount: 0,
        credit_amount: amount,
        memo: memo,
        location_id: location_id
      )
    else
      # DEBIT cash/bank, CREDIT revenue
      je.journal_entry_lines.build(
        chart_of_account: payment_account,
        debit_amount: amount,
        credit_amount: 0,
        memo: memo,
        location_id: location_id
      )
      je.journal_entry_lines.build(
        chart_of_account: category_account,
        debit_amount: 0,
        credit_amount: amount,
        memo: memo,
        location_id: location_id,
        **tags
      )
    end

    if je.save
      render json: {
        message: "#{memo_prefix} recorded",
        journal_entry: je.as_json(
          include: {
            journal_entry_lines: {
              include: { chart_of_account: { only: [:id, :account_number, :name] } }
            }
          }
        )
      }, status: :created
    else
      render json: { errors: je.errors }, status: :unprocessable_entity
    end
  end

  private

  def record_deal_payment(amount, payment_account)
    deal = @company.deals.where(deleted_at: nil).find_by(id: params[:apply_to_deal_id])
    return render(json: { error: 'Deal not found' }, status: :unprocessable_entity) unless deal
    return unless authorize_action!('accounting', 'create')

    bank = @company.bank_accounts.find_by(chart_of_account_id: payment_account.id)
    unless bank
      return render json: { error: "#{payment_account.name} isn't linked to a bank account, so it can't take a deal payment. Pick a bank account." },
                    status: :unprocessable_entity
    end

    service = DealPaymentService.new(deal, user: current_user)
    entry = service.build_entry(
      amount: amount, payment_date: params[:date].presence || Date.current, payment_method: params[:payment_method].presence || 'check',
      bank_account_id: bank.id, reference_number: params[:reference_number], memo: params[:memo]
    )
    receipt = service.record!(entry)
    invoice = @company.invoices.find_by(id: deal.reload.deal_invoice_id) if deal.deal_invoice_id
    render json: {
      message: receipt.amount_applied.to_d.positive? ? 'Payment recorded on the deal' : 'Deposit recorded on the deal',
      deal_payment: {
        deal_id: deal.id, deal_number: deal.deal_number, receipt_id: receipt.id, receipt_number: receipt.receipt_number,
        applied: receipt.amount_applied.to_f, held: receipt.amount_unapplied.to_f, owed: invoice&.amount_due&.to_f
      }
    }, status: :created
  rescue DealPaymentService::Error, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
