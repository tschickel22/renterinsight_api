# frozen_string_literal: true

class Api::V1::BankReconciliationsController < ApplicationController
  before_action :set_company_scope
  before_action :set_reconciliation, only: [:show, :toggle_item, :clear_all, :unclear_all, :complete, :add_adjustment, :destroy]

  def index
    return unless authorize_action!('bank_reconciliation', 'read')

    recs = @company.bank_reconciliations.includes(:bank_account, :completed_by).ordered
    recs = recs.where(bank_account_id: params[:bank_account_id]) if params[:bank_account_id].present?
    recs = recs.where(status: params[:status]) if params[:status].present?

    render json: {
      items: recs.as_json(
        include: {
          bank_account: { only: [:id, :bank_name, :account_type] },
          completed_by: { only: [:id, :email, :first_name, :last_name] }
        }
      )
    }
  end

  def show
    return unless authorize_action!('bank_reconciliation', 'read')

    items = @reconciliation.bank_reconciliation_items
      .includes(journal_entry_line: { journal_entry: :posted_by })
      .order('journal_entry_lines.id')

    deposits = items.select { |i| i.amount > 0 }
    payments = items.select { |i| i.amount <= 0 }

    render json: {
      reconciliation: @reconciliation.as_json(
        include: {
          bank_account: { only: [:id, :bank_name, :account_type] },
          completed_by: { only: [:id, :first_name, :last_name] }
        }
      ),
      deposits: deposits.map { |i| reconciliation_item_json(i) },
      payments: payments.map { |i| reconciliation_item_json(i) },
      summary: {
        total_items: items.count,
        cleared_items: items.cleared.count,
        uncleared_items: items.uncleared.count
      }
    }
  end

  def create
    return unless authorize_action!('bank_reconciliation', 'create')

    bank_account = @company.bank_accounts.find(params[:bank_account_id])
    service = BankReconciliationService.new(@company)

    result = service.start(
      bank_account: bank_account,
      statement_date: Date.parse(params[:statement_date]),
      statement_ending_balance: BigDecimal(params[:statement_ending_balance].to_s)
    )

    if result.is_a?(Hash) && result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: result, status: :created
    end
  end

  # POST /api/v1/bank_reconciliations/:id/toggle_item
  def toggle_item
    return unless authorize_action!('bank_reconciliation', 'update')

    item = @reconciliation.bank_reconciliation_items.find(params[:item_id])
    service = BankReconciliationService.new(@company)
    service.toggle_item(item)

    render json: @reconciliation.reload
  end

  # POST /api/v1/bank_reconciliations/:id/clear_all
  def clear_all
    return unless authorize_action!('bank_reconciliation', 'update')

    service = BankReconciliationService.new(@company)
    service.clear_all(@reconciliation)

    render json: @reconciliation.reload
  end

  # POST /api/v1/bank_reconciliations/:id/unclear_all
  def unclear_all
    return unless authorize_action!('bank_reconciliation', 'update')

    service = BankReconciliationService.new(@company)
    service.unclear_all(@reconciliation)

    render json: @reconciliation.reload
  end

  # POST /api/v1/bank_reconciliations/:id/complete
  def complete
    return unless authorize_action!('bank_reconciliation', 'update')

    service = BankReconciliationService.new(@company)
    result = service.complete(@reconciliation, current_user)

    if result
      render json: @reconciliation.reload
    else
      render json: { errors: @reconciliation.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/bank_reconciliations/:id/add_adjustment
  def add_adjustment
    return unless authorize_action!('bank_reconciliation', 'update')

    service = BankReconciliationService.new(@company)
    result = service.add_adjustment(
      @reconciliation,
      amount: BigDecimal(params[:amount].to_s),
      account_id: params[:account_id],
      memo: params[:memo],
      user: current_user
    )

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: { reconciliation: @reconciliation.reload, journal_entry: result[:journal_entry] }
    end
  end

  def destroy
    return unless authorize_action!('bank_reconciliation', 'delete')

    service = BankReconciliationService.new(@company)
    result = service.delete(@reconciliation)

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      head :no_content
    end
  end

  private

  def set_reconciliation
    @reconciliation = @company.bank_reconciliations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Reconciliation not found' }, status: :not_found
  end

  def reconciliation_item_json(item)
    line = item.journal_entry_line
    je = line.journal_entry

    {
      id: item.id,
      cleared: item.cleared,
      amount: item.amount,
      date: je.entry_date,
      entry_number: je.entry_number,
      memo: line.memo.presence || je.memo,
      source_type: je.source_type,
      journal_entry_id: je.id,
      journal_entry_line_id: line.id,
      posted_by: je.posted_by&.email
    }
  end
end
