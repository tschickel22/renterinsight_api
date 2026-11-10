# frozen_string_literal: true

class Api::V1::AccountLinksController < ApplicationController
  before_action :set_company_scope

  # Record types a mapping may point at, each found through the company so a
  # mapping can never name another company's record. Location is the only
  # type the settings form offers; the others are records posting checks for
  # an exact mapping.
  LINKABLE_SCOPES = {
    'Location' => :locations,
    'Deal' => :deals,
    'Vehicle' => :vehicles,
    'Part' => :parts
  }.freeze

  # Records the resolve preview accepts.
  RESOLVABLE_TYPES = %w[Location Deal].freeze

  # Purposes posting reads from mappings. Receivables and payables always
  # post to the Accounting Settings defaults.
  MAPPED_PURPOSES = %w[revenue cogs].freeze

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

    entity_type = params[:entity_type].to_s
    entity_id = params[:entity_id]
    purpose = params[:purpose].to_s

    entity = if RESOLVABLE_TYPES.include?(entity_type)
               @company.public_send(LINKABLE_SCOPES.fetch(entity_type)).find_by(id: entity_id)
             end
    return render json: { error: 'Entity not found' }, status: :not_found unless entity

    # Same lookup and fallback as deal closing and invoice posting, so the
    # preview shows the account a posting would actually use.
    location_id = entity.is_a?(Location) ? entity.id : entity.try(:location_id)
    mapped = if MAPPED_PURPOSES.include?(purpose)
               Accounting::AccountLinkResolver.resolve(company: @company, entity: entity, purpose: purpose,
                                                       location_id: location_id)
             end
    account = mapped || default_account_for(purpose)

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

  def default_account_for(purpose)
    settings = AccountingSettings.for_company(@company)
    case purpose
    when 'revenue'    then settings.default_sales_revenue_account
    when 'cogs'       then settings.default_cogs_account
    when 'receivable' then settings.default_ar_account
    when 'payable'    then settings.default_ap_account
    end
  end

  def link_params
    params.require(:account_link).permit(
      :linkable_type, :linkable_id, :link_purpose,
      :chart_of_account_id, :priority, :is_active
    )
  end
end
