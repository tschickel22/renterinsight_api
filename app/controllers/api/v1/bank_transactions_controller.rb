# frozen_string_literal: true

class Api::V1::BankTransactionsController < ApplicationController
  before_action :set_company_scope
  before_action :set_bank_account
  before_action :set_transaction, only: [:show, :categorize, :match, :exclude, :unmatch, :suggestions, :apply_payment, :payment_options]

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
      ).zip(transactions).map { |json, txn| json.merge(booked_to(txn)) },
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
    project = params[:project_id].present? ? @company.projects.not_deleted.find(params[:project_id]) : nil
    phase = project && params[:project_phase_id].present? ? project.project_phases.find(params[:project_phase_id]) : nil
    vendor = params[:vendor_id].present? ? @company.vendors.find(params[:vendor_id]) : nil

    @transaction.categorize!(
      account: account,
      contact: contact,
      memo: params[:memo],
      create_je: params[:create_je] == true || params[:create_je] == 'true',
      source: 'manual',
      project: project,
      project_phase: phase,
      vendor: vendor
    )

    render json: @transaction.reload.as_json.merge(booked_to(@transaction))
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: "Not found: #{e.model}" }, status: :unprocessable_entity
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/bank_accounts/:bank_account_id/transactions/:id/apply_payment
  # E99: a deposit that is a payment on a deal (fills its draws, or a deposit
  # before approval) or on an open invoice. Params: deal_id or invoice_id, memo.
  def apply_payment
    return unless authorize_action!('bank_accounts_accounting', 'update')
    return unless authorize_action!('accounting', 'create')

    deal = params[:deal_id].present? ? @company.deals.where(deleted_at: nil).find(params[:deal_id]) : nil
    invoice = params[:invoice_id].present? ? @company.invoices.not_deleted.find(params[:invoice_id]) : nil
    receipt = @transaction.apply_payment!(deal: deal, invoice: invoice, memo: params[:memo], user: current_user)
    render json: @transaction.reload.as_json.merge(booked_to(@transaction)).merge(
      receipt: { id: receipt.id, receipt_number: receipt.receipt_number, applied: receipt.amount_applied.to_f, held: receipt.amount_unapplied.to_f }
    )
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: "Not found: #{e.model}" }, status: :unprocessable_entity
  rescue BankTransaction::PostingError, BankTransaction::AlreadyBooked, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/v1/bank_accounts/:bank_account_id/transactions/:id/payment_options
  # E99: deals and open invoices a deposit could be a payment on. Ones whose
  # next draw or amount owed equals the deposit come first, marked exact.
  def payment_options
    return unless authorize_action!('bank_accounts_accounting', 'read')

    render json: BankFeedPaymentOptions.new(@company, @transaction, search: params[:search]).call
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

  # What a line was booked to, named for the feed list (E99).
  def booked_to(txn)
    {
      'project' => txn.project && { id: txn.project.id, name: txn.project.name, project_number: txn.project.project_number },
      'project_phase' => txn.project_phase && { id: txn.project_phase.id, name: txn.project_phase.name },
      'vendor' => txn.vendor && { id: txn.vendor.id, name: txn.vendor.name },
      'deal' => txn.deal && { id: txn.deal.id, deal_number: txn.deal.deal_number, name: txn.deal.try(:customer_display_name) },
      'invoice' => txn.invoice && { id: txn.invoice.id, invoice_number: txn.invoice.invoice_number },
      'cash_receipt' => txn.cash_receipt && { id: txn.cash_receipt.id, receipt_number: txn.cash_receipt.receipt_number }
    }
  end

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
