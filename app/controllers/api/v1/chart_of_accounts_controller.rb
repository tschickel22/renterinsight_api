# frozen_string_literal: true

class Api::V1::ChartOfAccountsController < ApplicationController
  include AccountingLocationScoping

  before_action :set_company_scope
  before_action :set_account, only: [:show, :update, :destroy]

  def index
    return unless authorize_action!('chart_of_accounts', 'read')

    if params[:format] == 'tree'
      tree = ChartOfAccount.tree_for_company(@company)
      balances = account_balances
      bank_balances = bank_account_balances
      attach_balances_to_tree!(tree, balances, bank_balances)
      render json: { tree: tree }
    else
      accounts = @company.chart_of_accounts.ordered

      stats = {
        total: accounts.count,
        active: accounts.where(is_active: true).count,
        inactive: accounts.where(is_active: false).count,
        by_type: accounts.reorder('').group(:account_type).count
      }

      if params[:search].present?
        search_term = "%#{params[:search]}%"
        accounts = accounts.where(
          "account_number ILIKE ? OR name ILIKE ? OR description ILIKE ?",
          search_term, search_term, search_term
        )
      end

      accounts = accounts.where(account_type: params[:account_type]) if params[:account_type].present?
      accounts = accounts.where(is_active: params[:is_active]) if params[:is_active].present?

      filtered_count = accounts.count

      page = (params[:page] || 1).to_i
      per_page = [(params[:per_page] || 50).to_i, 1000].min
      accounts = accounts.offset((page - 1) * per_page).limit(per_page)

      balances = account_balances
      bank_bals = bank_account_balances

      items = accounts.map do |acct|
        acct.as_json.merge(
          'balance' => balances[acct.id] || BigDecimal('0'),
          'bank_balance' => bank_bals[acct.id]
        )
      end

      render json: {
        items: items,
        meta: {
          total: filtered_count,
          page: page,
          per_page: per_page,
          total_pages: (filtered_count.to_f / per_page).ceil,
          stats: stats
        }
      }
    end
  end

  def show
    return unless authorize_action!('chart_of_accounts', 'read')
    render json: @account.as_json(include_balance: params[:include_balance])
  end

  def create
    return unless authorize_action!('chart_of_accounts', 'create')

    account = @company.chart_of_accounts.build(account_params)

    if account.save
      render json: account, status: :created
    else
      render json: { errors: account.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('chart_of_accounts', 'update')

    if @account.update(account_params)
      render json: @account
    else
      render json: { errors: @account.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('chart_of_accounts', 'delete')

    unless @account.destroyable?
      return render json: {
        error: @account.is_system ? 'Cannot delete system accounts' : 'Cannot delete accounts with transactions'
      }, status: :unprocessable_entity
    end

    @account.destroy
    head :no_content
  end

  # POST /api/v1/chart_of_accounts/import
  def import
    return unless authorize_action!('chart_of_accounts', 'create')

    accounts_data = params[:accounts] || []
    imported = 0
    errors_list = []

    accounts_data.each_with_index do |account_data, index|
      account = @company.chart_of_accounts.build(
        account_number: account_data[:account_number],
        name: account_data[:name],
        account_type: account_data[:account_type],
        sub_type: account_data[:sub_type],
        description: account_data[:description],
        is_header: account_data[:is_header] || false
      )

      if account.save
        imported += 1
      else
        errors_list << { row: index + 1, errors: account.errors.full_messages }
      end
    end

    render json: { imported: imported, errors: errors_list }
  end

  private

  def set_account
    @account = @company.chart_of_accounts.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Account not found' }, status: :not_found
  end

  def account_params
    params.require(:chart_of_account).permit(
      :account_number, :name, :description,
      :account_type, :sub_type, :normal_balance,
      :parent_id, :is_header, :is_active,
      :position, :bank_account_id
    )
  end

  # Calculate balance for every account from posted journal entry lines
  def account_balances
    query = JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id, is_void: false })

    if accounting_location_filtered?
      query = query.where(journal_entry_lines: { location_id: accounting_location_id })
    end

    rows = query
      .group(:chart_of_account_id)
      .pluck(
        Arel.sql('chart_of_account_id'),
        Arel.sql('COALESCE(SUM(debit_amount), 0)'),
        Arel.sql('COALESCE(SUM(credit_amount), 0)')
      )

    # Build a lookup of account_type by id
    type_map = @company.chart_of_accounts.pluck(:id, :normal_balance).to_h

    balances = {}
    rows.each do |acct_id, debits, credits|
      normal = type_map[acct_id] || 'debit'
      balances[acct_id] = normal == 'debit' ? (debits - credits) : (credits - debits)
    end
    balances
  end

  # Get bank balances for accounts linked to bank_accounts
  def bank_account_balances
    bank_accounts = @company.bank_accounts.where.not(chart_of_account_id: nil)
    result = {}
    bank_accounts.each do |ba|
      result[ba.chart_of_account_id] = ba.current_balance if ba.respond_to?(:current_balance)
    end
    result
  end

  # Recursively attach balances to tree nodes (uses symbol keys from build_node)
  def attach_balances_to_tree!(nodes, balances, bank_bals)
    return unless nodes.is_a?(Array)
    nodes.each do |node|
      id = node[:id]
      node[:balance] = balances[id] || BigDecimal('0')
      node[:bank_balance] = bank_bals[id]
      attach_balances_to_tree!(node[:children], balances, bank_bals)
    end
  end
end
