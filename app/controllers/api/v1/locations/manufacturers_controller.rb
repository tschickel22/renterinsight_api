# frozen_string_literal: true

class Api::V1::Locations::ManufacturersController < ApplicationController
  before_action :set_company_scope
  before_action :set_location
  before_action :set_location_manufacturer, only: [:update, :destroy]
  
  # GET /api/v1/locations/:location_id/manufacturers
  # Get manufacturers for this location with fallback to company settings
  def index
    return unless authorize_action!('company_settings', 'read')
    
    # Get all active manufacturers
    all_manufacturers = Manufacturer.active.alphabetical
    
    # Get location's selected manufacturers
    location_selected_ids = @location.location_manufacturers.pluck(:manufacturer_id)
    
    # Get company's selected manufacturers (for fallback)
    company_selected_ids = @company.company_manufacturers.pluck(:manufacturer_id)
    
    # Build response with selection status and dealer codes
    manufacturers_data = all_manufacturers.map do |manufacturer|
      location_manufacturer = @location.location_manufacturers.find_by(manufacturer_id: manufacturer.id)
      company_manufacturer = @company.company_manufacturers.find_by(manufacturer_id: manufacturer.id)
      
      {
        id: manufacturer.id,
        name: manufacturer.name,
        industryType: manufacturer.industry_type,
        contactEmail: manufacturer.contact_email,
        contactPhone: manufacturer.contact_phone,
        website: manufacturer.website,
        active: manufacturer.active,
        
        # Location-specific
        selectedAtLocation: location_selected_ids.include?(manufacturer.id),
        locationDealerCode: location_manufacturer&.dealer_code,
        locationManufacturerId: location_manufacturer&.id,
        locationNotes: location_manufacturer&.notes,
        
        # Company fallback
        selectedAtCompany: company_selected_ids.include?(manufacturer.id),
        companyDealerCode: company_manufacturer&.dealer_code,
        companyManufacturerId: company_manufacturer&.id,
        
        # Effective values (location overrides company)
        effectiveDealerCode: location_manufacturer&.dealer_code || company_manufacturer&.dealer_code,
        hasLocationOverride: location_manufacturer.present?
      }
    end
    
    render json: {
      manufacturers: manufacturers_data,
      locationSelectedCount: location_selected_ids.count,
      companySelectedCount: company_selected_ids.count,
      locationId: @location.id,
      locationName: @location.name
    }
  end
  
  # POST /api/v1/locations/:location_id/manufacturers
  # Add a manufacturer to this location with location-specific dealer code
  def create
    return unless authorize_action!('company_settings', 'update')
    
    manufacturer = Manufacturer.find(params[:manufacturer_id])
    
    location_manufacturer = @location.location_manufacturers.find_or_initialize_by(
      manufacturer_id: manufacturer.id
    )
    
    location_manufacturer.assign_attributes(
      dealer_code: params[:dealer_code],
      notes: params[:notes],
      active: true
    )
    
    if location_manufacturer.save
      Rails.logger.info("[Location Settings] #{current_user.email} added manufacturer #{manufacturer.name} to location #{@location.name}")
      render json: serialize_location_manufacturer(location_manufacturer), status: :created
    else
      render json: { errors: location_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # PATCH /api/v1/locations/:location_id/manufacturers/:id
  # Update dealer code or notes for a location-manufacturer relationship
  def update
    return unless authorize_action!('company_settings', 'update')
    
    if @location_manufacturer.update(update_params)
      Rails.logger.info("[Location Settings] #{current_user.email} updated manufacturer #{@location_manufacturer.manufacturer.name} for location #{@location.name}")
      render json: serialize_location_manufacturer(@location_manufacturer)
    else
      render json: { errors: @location_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # DELETE /api/v1/locations/:location_id/manufacturers/:id
  # Remove a manufacturer from this location (will fallback to company settings)
  def destroy
    return unless authorize_action!('company_settings', 'update')
    
    manufacturer_name = @location_manufacturer.manufacturer.name
    
    if @location_manufacturer.destroy
      Rails.logger.info("[Location Settings] #{current_user.email} removed manufacturer #{manufacturer_name} from location #{@location.name}")
      head :no_content
    else
      render json: { errors: @location_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  private
  
  def set_location
    @location = @company.locations.find(params[:location_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Location not found' }, status: :not_found
  end
  
  def set_location_manufacturer
    @location_manufacturer = @location.location_manufacturers.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Location manufacturer not found' }, status: :not_found
  end
  
  def update_params
    params.permit(:dealer_code, :notes, :active)
  end
  
  def serialize_location_manufacturer(location_manufacturer)
    {
      id: location_manufacturer.id,
      locationId: location_manufacturer.location_id,
      manufacturerId: location_manufacturer.manufacturer_id,
      manufacturerName: location_manufacturer.manufacturer.name,
      industryType: location_manufacturer.manufacturer.industry_type,
      dealerCode: location_manufacturer.dealer_code,
      active: location_manufacturer.active,
      notes: location_manufacturer.notes,
      createdAt: location_manufacturer.created_at,
      updatedAt: location_manufacturer.updated_at
    }
  end
end
