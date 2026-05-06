# frozen_string_literal: true

class Api::V1::ChartOfAccountsController < ApplicationController
  before_action :set_company_scope
  before_action :set_account, only: [:show, :update, :destroy]

  def index
    return unless authorize_action!('chart_of_accounts', 'read')

    if params[:format] == 'tree'
      tree = ChartOfAccount.tree_for_company(@company)
      render json: { tree: tree }
    else
      accounts = @company.chart_of_accounts.ordered

      stats = {
        total: accounts.count,
        active: accounts.where(is_active: true).count,
        inactive: accounts.where(is_active: false).count,
        by_type: accounts.group(:account_type).count
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
      per_page = [(params[:per_page] || 50).to_i, 200].min
      accounts = accounts.offset((page - 1) * per_page).limit(per_page)

      render json: {
        items: accounts,
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
end
