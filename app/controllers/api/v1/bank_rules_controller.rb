# frozen_string_literal: true

class Api::V1::BankRulesController < ApplicationController
  before_action :set_company_scope
  before_action :set_rule, only: [:show, :update, :destroy]

  def index
    return unless authorize_action!('bank_accounts_accounting', 'read')

    rules = @company.bank_rules.by_priority
    rules = rules.active if params[:active_only] == 'true'
    rules = rules.where(bank_account_id: params[:bank_account_id]) if params[:bank_account_id].present?

    render json: {
      items: rules.as_json(
        include: {
          assign_account: { only: [:id, :account_number, :name] },
          assign_contact: { only: [:id, :first_name, :last_name, :company_name] },
          bank_account: { only: [:id, :bank_name] }
        }
      )
    }
  end

  def show
    return unless authorize_action!('bank_accounts_accounting', 'read')
    render json: @rule
  end

  def create
    return unless authorize_action!('bank_accounts_accounting', 'create')

    rule = @company.bank_rules.build(rule_params)

    if rule.save
      render json: rule.as_json(
        include: { assign_account: { only: [:id, :account_number, :name] } }
      ), status: :created
    else
      render json: { errors: rule.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('bank_accounts_accounting', 'update')

    if @rule.update(rule_params)
      render json: @rule
    else
      render json: { errors: @rule.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('bank_accounts_accounting', 'delete')

    @rule.destroy
    head :no_content
  end

  # POST /api/v1/bank_rules/test
  def test
    return unless authorize_action!('bank_accounts_accounting', 'read')

    rule = @company.bank_rules.build(rule_params)

    scope = BankTransaction.where(company_id: @company.id, status: 'unmatched')
    scope = scope.where(bank_account_id: rule.bank_account_id) if rule.bank_account_id.present?

    matches = scope.select { |txn| rule.matches?(txn) }

    render json: {
      match_count: matches.count,
      sample_matches: matches.first(5).map { |t|
        {
          id: t.id,
          date: t.transaction_date,
          description: t.description,
          amount: t.amount,
          bank_account_id: t.bank_account_id
        }
      }
    }
  end

  # POST /api/v1/bank_rules/create_from_transaction
  def create_from_transaction
    return unless authorize_action!('bank_accounts_accounting', 'create')

    txn = BankTransaction.where(company_id: @company.id).find(params[:transaction_id])

    rule = @company.bank_rules.build(
      name: "Auto: #{txn.description&.truncate(40)}",
      bank_account_id: txn.bank_account_id,
      match_type: 'contains',
      match_field: 'description',
      match_value: extract_rule_pattern(txn.description),
      transaction_direction: txn.deposit? ? 'deposit' : 'withdrawal',
      assign_account_id: txn.category_account_id,
      assign_contact_id: txn.contact_id,
      assign_memo: txn.memo,
      auto_confirm: false,
      priority: 100,
      is_active: true
    )

    if rule.save
      render json: rule, status: :created
    else
      render json: { errors: rule.errors }, status: :unprocessable_entity
    end
  end

  private

  def set_rule
    @rule = @company.bank_rules.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Rule not found' }, status: :not_found
  end

  def rule_params
    params.require(:bank_rule).permit(
      :name, :bank_account_id, :match_type, :match_field, :match_value,
      :min_amount, :max_amount, :transaction_direction,
      :assign_account_id, :assign_contact_id, :assign_memo,
      :auto_confirm, :priority, :is_active
    )
  end

  def extract_rule_pattern(description)
    return '' if description.blank?
    cleaned = description.gsub(/\d{4,}/, '')
                         .gsub(/\$[\d,.]+/, '')
                         .gsub(/\s{2,}/, ' ')
                         .strip
    cleaned.first(50)
  end
end
