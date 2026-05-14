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
  #   contact_id: optional
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

    unless category_account && payment_account
      return render json: { error: 'Both category_account_id and payment_account_id are required' }, status: :bad_request
    end

    location_id = params[:location_id].presence || Current.location_id
    party_name = type == 'expense' ? params[:vendor_name] : params[:customer_name]
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
        contact_id: params[:contact_id].presence
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
        contact_id: params[:contact_id].presence
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
end
