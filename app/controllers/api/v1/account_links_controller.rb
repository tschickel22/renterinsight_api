# frozen_string_literal: true

class Api::V1::AccountLinksController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('accounting', 'read')

    links = @company.account_links.active.includes(:chart_of_account)
    links = links.where(linkable_type: params[:linkable_type]) if params[:linkable_type].present?
    links = links.for_purpose(params[:purpose]) if params[:purpose].present?

    render json: links.as_json(
      include: { chart_of_account: { only: [:id, :account_number, :name, :account_type] } }
    )
  end

  def create
    return unless authorize_action!('accounting', 'create')

    link = @company.account_links.build(link_params)

    if link.save
      render json: link.as_json(
        include: { chart_of_account: { only: [:id, :account_number, :name] } }
      ), status: :created
    else
      render json: { errors: link.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('accounting', 'update')

    link = @company.account_links.find(params[:id])

    if link.update(link_params)
      render json: link
    else
      render json: { errors: link.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('accounting', 'delete')

    link = @company.account_links.find(params[:id])
    link.destroy
    head :no_content
  end

  # POST /api/v1/account_links/resolve
  def resolve
    return unless authorize_action!('accounting', 'read')

    entity_type = params[:entity_type]
    entity_id = params[:entity_id]
    purpose = params[:purpose]

    entity = entity_type.constantize.find(entity_id) rescue nil
    return render json: { error: 'Entity not found' }, status: :not_found unless entity

    account = AccountLinkResolver.resolve(company: @company, entity: entity, purpose: purpose)

    render json: {
      resolved_account: account ? {
        id: account.id,
        account_number: account.account_number,
        name: account.name
      } : nil,
      purpose: purpose,
      entity_type: entity_type,
      entity_id: entity_id
    }
  end

  private

  def link_params
    params.require(:account_link).permit(
      :linkable_type, :linkable_id, :link_purpose,
      :chart_of_account_id, :priority, :is_active
    )
  end
end
