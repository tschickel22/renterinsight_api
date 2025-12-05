# frozen_string_literal: true

class Api::Company::ManufacturersController < ApplicationController
  before_action :set_company_scope
  before_action :set_company_manufacturer, only: [:update, :destroy]
  
  # GET /api/company/manufacturers
  # Get manufacturers available for this company based on industry type
  def index
    return unless authorize_action!('company_settings', 'read')
    
    # Get company's industry type from settings or locations
    industry_types = determine_company_industry_types
    
    # Get all manufacturers that match company's industry
    available_manufacturers = Manufacturer.active.where(
      'industry_type IN (?) OR industry_type = ?',
      industry_types,
      'both'
    ).alphabetical
    
    # Get company's selected manufacturers
    selected_ids = @company.company_manufacturers.pluck(:manufacturer_id)
    
    # Build response with selection status and dealer codes
    manufacturers_data = available_manufacturers.map do |manufacturer|
      company_manufacturer = @company.company_manufacturers.find_by(manufacturer_id: manufacturer.id)
      
      {
        id: manufacturer.id,
        name: manufacturer.name,
        industryType: manufacturer.industry_type,
        contactEmail: manufacturer.contact_email,
        contactPhone: manufacturer.contact_phone,
        website: manufacturer.website,
        active: manufacturer.active,
        selected: selected_ids.include?(manufacturer.id),
        dealerCode: company_manufacturer&.dealer_code,
        companyManufacturerId: company_manufacturer&.id,
        notes: company_manufacturer&.notes
      }
    end
    
    render json: {
      manufacturers: manufacturers_data,
      selectedCount: selected_ids.count,
      industryTypes: industry_types
    }
  end
  
  # POST /api/company/manufacturers
  # Select a manufacturer for this company
  def create
    return unless authorize_action!('company_settings', 'update')
    
    manufacturer = Manufacturer.find(params[:manufacturer_id])
    
    company_manufacturer = @company.company_manufacturers.find_or_initialize_by(
      manufacturer_id: manufacturer.id
    )
    
    company_manufacturer.assign_attributes(
      dealer_code: params[:dealer_code],
      notes: params[:notes],
      active: true
    )
    
    if company_manufacturer.save
      Rails.logger.info("[Company Settings] #{current_user.email} added manufacturer #{manufacturer.name} to company #{@company.name}")
      render json: serialize_company_manufacturer(company_manufacturer), status: :created
    else
      render json: { errors: company_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # PATCH /api/company/manufacturers/:id
  # Update dealer code or notes for a company-manufacturer relationship
  def update
    return unless authorize_action!('company_settings', 'update')
    
    if @company_manufacturer.update(update_params)
      Rails.logger.info("[Company Settings] #{current_user.email} updated manufacturer #{@company_manufacturer.manufacturer.name} for company #{@company.name}")
      render json: serialize_company_manufacturer(@company_manufacturer)
    else
      render json: { errors: @company_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # DELETE /api/company/manufacturers/:id
  # Remove a manufacturer from this company
  def destroy
    return unless authorize_action!('company_settings', 'update')
    
    manufacturer_name = @company_manufacturer.manufacturer.name
    
    if @company_manufacturer.destroy
      Rails.logger.info("[Company Settings] #{current_user.email} removed manufacturer #{manufacturer_name} from company #{@company.name}")
      head :no_content
    else
      render json: { errors: @company_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_company_manufacturer
    @company_manufacturer = @company.company_manufacturers.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Company manufacturer not found' }, status: :not_found
  end
  
  def update_params
    params.permit(:dealer_code, :notes, :active)
  end
  
  def determine_company_industry_types
    # Since locations don't have a location_type column,
    # we'll default to showing all manufacturer types (both)
    # Companies can select any manufacturers they work with
    ['rv', 'manufactured_home', 'both']
  end
  
  def serialize_company_manufacturer(company_manufacturer)
    {
      id: company_manufacturer.id,
      companyId: company_manufacturer.company_id,
      manufacturerId: company_manufacturer.manufacturer_id,
      manufacturerName: company_manufacturer.manufacturer.name,
      industryType: company_manufacturer.manufacturer.industry_type,
      dealerCode: company_manufacturer.dealer_code,
      active: company_manufacturer.active,
      notes: company_manufacturer.notes,
      createdAt: company_manufacturer.created_at,
      updatedAt: company_manufacturer.updated_at
    }
  end
end
