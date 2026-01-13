class Api::V1::CommissionRulesController < ApplicationController
  before_action :set_company_scope
  before_action :set_commission_rule, only: [:show, :update, :destroy]

  def index
    return unless authorize_action!('commissions', 'read')

    rules = @company.commission_rules.order(created_at: :desc)

    # Filter by active status if requested
    rules = rules.where(is_active: params[:is_active]) if params[:is_active].present?

    render json: {
      commission_rules: rules.map { |rule| serialize_rule(rule) }
    }
  end

  def show
    return unless authorize_action!('commissions', 'read')
    render json: { commission_rule: serialize_rule(@commission_rule) }
  end

  def create
    return unless authorize_action!('commissions', 'create')

    rule = @company.commission_rules.build(rule_params)

    if rule.save
      render json: { commission_rule: serialize_rule(rule) }, status: :created
    else
      render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('commissions', 'update')

    if @commission_rule.update(rule_params)
      render json: { commission_rule: serialize_rule(@commission_rule) }
    else
      render json: { errors: @commission_rule.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('commissions', 'delete')

    # Check if rule is being used by any commissions
    if @commission_rule.commissions.exists?
      render json: { 
        error: 'Cannot delete commission rule that is being used by commissions. Deactivate it instead.' 
      }, status: :unprocessable_entity
      return
    end

    @commission_rule.destroy
    head :no_content
  end

  def calculate
    return unless authorize_action!('commissions', 'read')

    rule = @company.commission_rules.find(params[:id])
    deal_amount = params[:deal_amount].to_f

    if deal_amount <= 0
      render json: { error: 'Deal amount must be greater than 0' }, status: :unprocessable_entity
      return
    end

    calculated_amount = rule.calculate(deal_amount)

    render json: {
      rule_id: rule.id,
      rule_name: rule.name,
      rule_type: rule.rule_type,
      deal_amount: deal_amount,
      commission_amount: calculated_amount
    }
  end

  private

  def set_commission_rule
    @commission_rule = @company.commission_rules.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Commission rule not found' }, status: :not_found
  end

  def rule_params
    params.require(:commission_rule).permit(
      :name,
      :rule_type,
      :rate,
      :amount,
      :is_active,
      :description,
      tiers: [:min, :max, :rate]
    )
  end

  def serialize_rule(rule)
    {
      id: rule.id,
      name: rule.name,
      type: rule.rule_type,
      rate: rule.rate,
      amount: rule.amount,
      tiers: rule.tiers,
      isActive: rule.is_active,
      description: rule.description,
      createdAt: rule.created_at,
      updatedAt: rule.updated_at
    }
  end
end
