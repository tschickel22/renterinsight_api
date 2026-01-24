class Api::Admin::ManufacturersController < ApplicationController
  Rails.logger.info "[ManufacturersController] Controller class loaded"
  
  before_action :require_platform_admin
  before_action :set_manufacturer, only: [:show, :update, :destroy, :activate, :deactivate]

  # GET /api/admin/manufacturers
  def index
    manufacturers = Manufacturer.all

    # Apply filters
    if params[:industry_type].present?
      manufacturers = manufacturers.where(industry_type: params[:industry_type])
    end

    if params[:active].present?
      manufacturers = manufacturers.where(active: params[:active] == 'true')
    end

    if params[:search].present?
      search_term = "%#{params[:search].downcase}%"
      manufacturers = manufacturers.where(
        "LOWER(name) LIKE ? OR LOWER(contact_email) LIKE ? OR LOWER(contact_phone) LIKE ?",
        search_term, search_term, search_term
      )
    end

    manufacturers = manufacturers.order(:name)

    render json: manufacturers.map { |m| serialize_manufacturer(m) }
  end

  # GET /api/admin/manufacturers/:id
  def show
    render json: serialize_manufacturer(@manufacturer, include_stats: true)
  end

  # POST /api/admin/manufacturers
  def create
    manufacturer = Manufacturer.new(manufacturer_params)

    if manufacturer.save
      Rails.logger.info("[Admin] Platform admin #{current_user.email} created manufacturer: #{manufacturer.name}")
      render json: serialize_manufacturer(manufacturer), status: :created
    else
      render json: { errors: manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/admin/manufacturers/:id
  def update
    Rails.logger.info("[Manufacturers#update] Updating manufacturer #{@manufacturer.id}")
    Rails.logger.info("[Manufacturers#update] Params: #{manufacturer_params.inspect}")
    
    if @manufacturer.update(manufacturer_params)
      Rails.logger.info("[Admin] Platform admin #{current_user.email} updated manufacturer: #{@manufacturer.name}")
      render json: serialize_manufacturer(@manufacturer)
    else
      Rails.logger.error("[Manufacturers#update] Failed to update: #{@manufacturer.errors.full_messages}")
      render json: { errors: @manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/admin/manufacturers/:id (soft delete via deactivate)
  def destroy
    if @manufacturer.deactivate!
      Rails.logger.info("[Admin] Platform admin #{current_user.email} deactivated manufacturer: #{@manufacturer.name}")
      head :no_content
    else
      render json: { error: 'Failed to deactivate manufacturer' }, status: :unprocessable_entity
    end
  end

  # POST /api/admin/manufacturers/:id/activate
  def activate
    if @manufacturer.activate!
      Rails.logger.info("[Admin] Platform admin #{current_user.email} activated manufacturer: #{@manufacturer.name}")
      render json: serialize_manufacturer(@manufacturer)
    else
      render json: { error: 'Failed to activate manufacturer' }, status: :unprocessable_entity
    end
  end

  # POST /api/admin/manufacturers/:id/deactivate
  def deactivate
    if @manufacturer.deactivate!
      Rails.logger.info("[Admin] Platform admin #{current_user.email} deactivated manufacturer: #{@manufacturer.name}")
      render json: serialize_manufacturer(@manufacturer)
    else
      render json: { error: 'Failed to deactivate manufacturer' }, status: :unprocessable_entity
    end
  end

  private

  def require_platform_admin
    unless current_user&.role == 'platform_admin'
      render json: { error: 'Unauthorized - Platform admin access required' }, status: :forbidden
    end
  end

  def set_manufacturer
    @manufacturer = Manufacturer.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Manufacturer not found' }, status: :not_found
  end

  def manufacturer_params
    params.require(:manufacturer).permit(
      :name,
      :industry_type,
      :contact_email,
      :contact_phone,
      :website,
      :notes,
      :active,
      :has_portal_access,
      :portal_url
    )
  end

  def serialize_manufacturer(manufacturer, include_stats: false)
    data = {
      id: manufacturer.id,
      name: manufacturer.name,
      industryType: manufacturer.industry_type,
      contactEmail: manufacturer.contact_email,
      contactPhone: manufacturer.contact_phone,
      website: manufacturer.website,
      notes: manufacturer.notes,
      active: manufacturer.active,
      hasPortalAccess: manufacturer.has_portal_access,
      portalUrl: manufacturer.portal_url,
      oemCodes: manufacturer.oem_codes || {},
      metadata: manufacturer.metadata || {},
      createdAt: manufacturer.created_at,
      updatedAt: manufacturer.updated_at
    }

    if include_stats
      data[:stats] = {
        totalClaims: manufacturer.total_claims_count,
        activeClaims: manufacturer.active_claims_count,
        approvedClaims: manufacturer.approved_claims_count,
        totalArOutstanding: manufacturer.total_ar_outstanding
      }
    end

    data
  end
end
