class Api::V1::CampaignSuppressionsController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('campaigns', 'read')

    suppressions = CampaignSuppression.where(company_id: @company.id)
    suppressions = suppressions.where(reason: params[:reason]) if params[:reason].present?

    case params[:contact_type]
    when 'email' then suppressions = suppressions.where.not(email_address: nil)
    when 'phone' then suppressions = suppressions.where.not(phone_number: nil)
    end

    if params[:search].present?
      term = "%#{params[:search].downcase}%"
      suppressions = suppressions.where('email_address ILIKE ? OR phone_number ILIKE ?', term, term)
    end

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    total = suppressions.count
    suppressions = suppressions.order(suppressed_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: suppressions.map { |s| { id: s.id, email_address: s.email_address, phone_number: s.phone_number, reason: s.reason, suppressed_at: s.suppressed_at, notes: s.notes } },
      meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
    }
  end

  def create
    return unless authorize_action!('campaigns', 'update')

    email = params[:email_address].presence
    phone = params[:phone_number].presence

    if email.blank? && phone.blank?
      return render(json: { error: 'Either email_address or phone_number is required' }, status: :unprocessable_entity)
    end

    if email.present? && phone.present?
      return render(json: { error: 'Provide email_address OR phone_number, not both' }, status: :unprocessable_entity)
    end

    s = CampaignSuppression.new(
      company_id: @company.id,
      email_address: email,
      phone_number: phone,
      reason: params[:reason] || 'manual',
      notes: params[:notes]
    )

    if s.save
      render json: { id: s.id, email_address: s.email_address, phone_number: s.phone_number, reason: s.reason }, status: :created
    else
      render json: { errors: s.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('campaigns', 'update')
    s = CampaignSuppression.where(company_id: @company.id).find(params[:id])
    s.destroy
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Suppression not found' }, status: :not_found
  end
end
