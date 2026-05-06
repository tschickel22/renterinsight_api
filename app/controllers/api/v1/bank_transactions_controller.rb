# frozen_string_literal: true

class Api::V1::BankTransactionsController < ApplicationController
  before_action :set_company_scope
  before_action :set_bank_account
  before_action :set_transaction, only: [:show, :categorize, :match, :exclude, :unmatch, :suggestions]

  def index
    return unless authorize_action!('bank_accounts_accounting', 'read')

    transactions = @bank_account.bank_transactions.ordered

    stats = {
      total: transactions.count,
      unmatched: transactions.unmatched.count,
      matched: transactions.matched.count,
      excluded: transactions.excluded.count,
      reconciled: transactions.reconciled.count
    }

    transactions = transactions.where(status: params[:status]) if params[:status].present?
    if params[:start_date].present? && params[:end_date].present?
      transactions = transactions.for_date_range(params[:start_date], params[:end_date])
    end
    transactions = transactions.deposits if params[:direction] == 'deposit'
    transactions = transactions.withdrawals if params[:direction] == 'withdrawal'

    if params[:search].present?
      search_term = "%#{params[:search]}%"
      transactions = transactions.where(
        "description ILIKE ? OR reference_number ILIKE ? OR memo ILIKE ?",
        search_term, search_term, search_term
      )
    end

    filtered_count = transactions.count

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    transactions = transactions.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: transactions.as_json(
        include: {
          category_account: { only: [:id, :account_number, :name] },
          matched_journal_entry: { only: [:id, :entry_number, :entry_date, :memo] },
          rule: { only: [:id, :name] },
          contact: { only: [:id, :first_name, :last_name, :company_name] }
        }
      ),
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: stats
      }
    }
  end

  def show
    return unless authorize_action!('bank_accounts_accounting', 'read')
    render json: @transaction.as_json(
      include: {
        category_account: { only: [:id, :account_number, :name] },
        matched_journal_entry: {
          include: { journal_entry_lines: { include: { chart_of_account: { only: [:id, :account_number, :name] } } } }
        },
        rule: { only: [:id, :name] },
        contact: { only: [:id, :first_name, :last_name] }
      }
    )
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/:id/categorize
  def categorize
    return unless authorize_action!('bank_accounts_accounting', 'update')

    account = @company.chart_of_accounts.find(params[:account_id])
    contact = params[:contact_id].present? ? @company.contacts.find(params[:contact_id]) : nil

    @transaction.categorize!(
      account: account,
      contact: contact,
      memo: params[:memo],
      create_je: params[:create_je] == true || params[:create_je] == 'true',
      source: 'manual'
    )

    render json: @transaction.reload
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/:id/match
  def match
    return unless authorize_action!('bank_accounts_accounting', 'update')

    je = @company.journal_entries.find(params[:journal_entry_id])
    @transaction.match_to_journal_entry!(je, source: 'manual')

    render json: @transaction.reload
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/:id/exclude
  def exclude
    return unless authorize_action!('bank_accounts_accounting', 'update')

    @transaction.exclude!(reason: params[:reason])
    render json: @transaction
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/:id/unmatch
  def unmatch
    return unless authorize_action!('bank_accounts_accounting', 'update')

    @transaction.unmatch!
    render json: @transaction
  end

  # GET /api/v1/bank_accounts/:bank_account_id/transactions/:id/suggestions
  def suggestions
    return unless authorize_action!('bank_accounts_accounting', 'read')

    matcher = BankTransactionMatchingService.new(@company)
    matches = matcher.suggest_matches(@transaction, limit: params[:limit]&.to_i || 5)

    render json: { suggestions: matches }
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/auto_match
  def auto_match
    return unless authorize_action!('bank_accounts_accounting', 'update')

    matcher = BankTransactionMatchingService.new(@company)
    matched_count = matcher.auto_match_all(@bank_account)

    render json: { matched: matched_count, remaining: @bank_account.bank_transactions.unmatched.count }
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/import_csv
  def import_csv
    return unless authorize_action!('bank_accounts_accounting', 'create')

    rows = params[:rows] || []
    column_map = (params[:column_map] || {}).to_unsafe_h.symbolize_keys

    service = BankTransactionImportService.new(@company)
    result = service.import(bank_account: @bank_account, rows: rows, column_map: column_map)

    render json: result
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/bulk_action
  def bulk_action
    return unless authorize_action!('bank_accounts_accounting', 'update')

    transaction_ids = params[:transaction_ids] || []
    action = params[:bulk_action]
    transactions = @bank_account.bank_transactions.where(id: transaction_ids)

    case action
    when 'exclude'
      transactions.each { |t| t.exclude!(reason: params[:reason]) }
    when 'unmatch'
      transactions.each { |t| t.unmatch! }
    else
      return render json: { error: "Unknown action: #{action}" }, status: :bad_request
    end

    render json: { updated: transactions.count }
  end

  private

  def set_bank_account
    @bank_account = @company.bank_accounts.find(params[:bank_account_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Bank account not found' }, status: :not_found
  end

  def set_transaction
    @transaction = @bank_account.bank_transactions.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Transaction not found' }, status: :not_found
  end
end
