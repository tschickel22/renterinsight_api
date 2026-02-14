# frozen_string_literal: true

# Public::InventoryController - Public vehicle catalog API
# Authentication: Token-based (public_inventory_token) - no user authentication required
# 
# Endpoints:
# - GET /public/inventory - List vehicles with filtering/pagination
# - GET /public/inventory/:id - Single vehicle details
# - GET /public/inventory/filters - Available filter options
#
# Usage:
# - Token passed via params[:token] or X-Inventory-Token header
# - Optional website_id/location_id for context-specific branding
class Public::InventoryController < ApplicationController
  skip_before_action :authenticate, raise: false  # Public endpoint - no user auth
  skip_before_action :set_company_scope, raise: false  # Company determined by token
  skip_before_action :set_current_attributes, raise: false  # No user context
  
  before_action :authenticate_inventory_token
  before_action :check_public_inventory_enabled
  before_action :set_vehicle, only: [:show]
  
  # GET /public/inventory
  # List all available vehicles with filtering, sorting, and pagination
  #
  # Params:
  # - token (required): Public inventory token
  # - website_id (optional): For website-specific branding
  # - location_id (optional): Filter by location + location branding
  # - statuses (optional): Comma-separated list of statuses to show (e.g., 'available,available_to_order')
  # - min_price, max_price: Price range filtering
  # - bedrooms, bathrooms: Manufactured home filters
  # - make, model, year: Vehicle filters
  # - listing_type: 'rv' or 'manufactured_home'
  # - square_feet_min, square_feet_max: Square footage range
  # - search: Search across inventory_id, make, model, description
  # - sort_by: Field to sort by (default: created_at)
  # - sort_order: 'asc' or 'desc' (default: desc)
  # - page: Page number (default: 1)
  # - per_page: Items per page (default: company.items_per_page or 12, max: 50)
  def index
    # Base query - use statuses from params or fallback to company's public_statuses
    statuses = if params[:statuses].present?
      params[:statuses].split(',').map(&:strip)
    else
      get_public_statuses
    end
    
    @vehicles = @company.vehicles
                       .where(status: statuses)
                       .where(is_deleted: [false, nil])
    
    # Location filtering
    if params[:location_id].present?
      @vehicles = @vehicles.where(location_id: params[:location_id])
    end
    
    # Price filtering (prices stored as decimal dollars, not cents)
    if params[:min_price].present?
      @vehicles = @vehicles.where('sale_price >= ?', params[:min_price].to_f)
    end
    
    if params[:max_price].present?
      @vehicles = @vehicles.where('sale_price <= ?', params[:max_price].to_f)
    end
    
    # Manufactured home filters
    if params[:bedrooms].present?
      @vehicles = @vehicles.where(bedrooms: params[:bedrooms])
    end
    
    if params[:bathrooms].present?
      @vehicles = @vehicles.where(bathrooms: params[:bathrooms])
    end
    
    if params[:square_feet_min].present?
      @vehicles = @vehicles.where('square_feet >= ?', params[:square_feet_min])
    end
    
    if params[:square_feet_max].present?
      @vehicles = @vehicles.where('square_feet <= ?', params[:square_feet_max])
    end
    
    # Sections filter
    if params[:sections].present?
      @vehicles = @vehicles.where(sections: params[:sections])
    end
    
    # Condition filter
    if params[:condition].present?
      @vehicles = @vehicles.where(condition: params[:condition])
    end
    
    # Vehicle filters
    @vehicles = @vehicles.where(make: params[:make]) if params[:make].present?
    @vehicles = @vehicles.where(model: params[:model]) if params[:model].present?
    @vehicles = @vehicles.where(year: params[:year]) if params[:year].present?
    @vehicles = @vehicles.where(listing_type: params[:listing_type]) if params[:listing_type].present?
    
    # Search across multiple fields
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      @vehicles = @vehicles.where(
        "inventory_id ILIKE ? OR make ILIKE ? OR model ILIKE ? OR description ILIKE ?",
        search_term, search_term, search_term, search_term
      )
    end
    
    # Sorting
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    
    # Validate sort_by to prevent SQL injection
    allowed_sort_fields = %w[created_at sale_price year make model mileage square_feet bedrooms bathrooms sections]
    sort_by = 'created_at' unless allowed_sort_fields.include?(sort_by)
    
    @vehicles = @vehicles.order(sort_by => sort_order)
    
    # Pagination
    page = (params[:page] || 1).to_i
    default_per_page = get_items_per_page
    per_page = (params[:per_page] || default_per_page).to_i
    per_page = [per_page, 50].min  # Cap at 50 items
    
    total_count = @vehicles.count
    total_pages = (total_count.to_f / per_page).ceil
    
    @vehicles = @vehicles.offset((page - 1) * per_page).limit(per_page)
    
    # Get branding (Location → Company → Platform hierarchy)
    location = params[:location_id].present? ? @company.locations.find_by(id: params[:location_id]) : nil
    branding = resolve_branding(location)
    
    render json: {
      items: @vehicles.map { |v| vehicle_list_json(v) },
      meta: {
        total: total_count,
        page: page,
        per_page: per_page,
        total_pages: total_pages,
        company: {
          id: @company.id,
          name: @company.name
        },
        branding: branding
      }
    }
  end
  
  # GET /public/inventory/:id
  # Get detailed information for a single vehicle
  #
  # Params:
  # - token (required): Public inventory token
  # - website_id (optional): For website-specific branding
  # - location_id (optional): For location-specific branding
  def show
    # Get branding (Location → Company → Platform hierarchy)
    location = @vehicle.location || 
               (params[:location_id].present? ? @company.locations.find_by(id: params[:location_id]) : nil)
    branding = resolve_branding(location)
    
    # Contact info - from location if available, otherwise company name only
    company_data = {
      name: @company.name,
      phone: location&.phone,
      email: location&.email,
      address: location&.address_line1,
      city: location&.city,
      state: location&.state,
      zip: location&.zip_code
    }
    
    render json: {
      vehicle: vehicle_detail_json(@vehicle),
      company: company_data,
      branding: branding
    }
  end
  
  # GET /public/inventory/filters
  # Get available filter options (makes, models, years, locations, price ranges)
  #
  # Params:
  # - token (required): Public inventory token
  def filters
    # Only include vehicles in public_statuses
    statuses = get_public_statuses
    vehicles = @company.vehicles
                      .where(status: statuses)
                      .where(is_deleted: [false, nil])
    
    # Get unique values for filters
    makes = vehicles.where.not(make: [nil, '']).distinct.pluck(:make).compact.sort
    models = vehicles.where.not(model: [nil, '']).distinct.pluck(:model).compact.sort
    years = vehicles.where.not(year: nil).distinct.pluck(:year).compact.sort.reverse
    types = vehicles.where.not(listing_type: [nil, '']).distinct.pluck(:listing_type).compact
    conditions = vehicles.where.not(condition: [nil, '']).distinct.pluck(:condition).compact.sort
    
    # Manufactured home specific options
    bedrooms = vehicles.where.not(bedrooms: nil).distinct.pluck(:bedrooms).compact.sort
    bathrooms = vehicles.where.not(bathrooms: nil).distinct.pluck(:bathrooms).compact.sort
    sections = vehicles.where.not(sections: nil).distinct.pluck(:sections).compact.sort
    
    # Square footage range
    sqft_values = vehicles.where.not(square_feet: nil).pluck(:square_feet).compact.map(&:to_i)
    sqft_range = if sqft_values.any?
      { min: sqft_values.min, max: sqft_values.max }
    else
      { min: 0, max: 0 }
    end
    
    # Models grouped by make (for cascading dropdowns)
    models_by_make = {}
    vehicles.where.not(make: [nil, '']).where.not(model: [nil, '']).distinct.pluck(:make, :model).each do |make, model|
      models_by_make[make] ||= []
      models_by_make[make] << model unless models_by_make[make].include?(model)
    end
    models_by_make.each { |k, v| models_by_make[k] = v.sort }
    
    # Location filter options
    location_ids = vehicles.where.not(location_id: nil).distinct.pluck(:location_id)
    locations = @company.locations.where(id: location_ids).map do |loc|
      {
        id: loc.id,
        name: loc.name,
        city: loc.city,
        state: loc.state
      }
    end
    
    # Price range (prices stored as decimal dollars, not cents)
    prices = vehicles.where.not(sale_price: nil).pluck(:sale_price).map(&:to_f)
    price_range = if prices.any?
      {
        min: prices.min.round(2),
        max: prices.max.round(2)
      }
    else
      { min: 0, max: 0 }
    end
    
    render json: {
      makes: makes,
      models: models,
      models_by_make: models_by_make,
      years: years,
      types: types,
      conditions: conditions,
      bedrooms: bedrooms,
      bathrooms: bathrooms,
      sections: sections,
      locations: locations,
      price_range: price_range,
      sqft_range: sqft_range,
      total_count: vehicles.count
    }
  end
  
  private
  
  # Authenticate using public_inventory_token
  # Token can be in params[:token] or X-Inventory-Token header
  def authenticate_inventory_token
    token = params[:token] || request.headers['X-Inventory-Token']
    
    if token.blank?
      render json: { error: 'Missing inventory token' }, status: :unauthorized
      return
    end
    
    @company = Company.find_by(public_inventory_token: token)
    
    unless @company
      render json: { error: 'Invalid inventory token' }, status: :unauthorized
      return
    end
  end
  
  # Check if public inventory is enabled for this company
  def check_public_inventory_enabled
    unless @company.public_inventory_enabled
      render json: { error: 'Public inventory access is disabled' }, status: :forbidden
      return
    end
  end
  
  # Find vehicle by ID and verify it's available for public viewing
  def set_vehicle
    @vehicle = @company.vehicles.find_by(id: params[:id])
    
    unless @vehicle
      render json: { error: 'Vehicle not found' }, status: :not_found
      return
    end
    
    # Check if vehicle was deleted
    if @vehicle.is_deleted
      render json: { error: 'Vehicle no longer available' }, status: :gone
      return
    end
    
    # Check if vehicle status is in public_statuses
    statuses = get_public_statuses
    unless statuses.include?(@vehicle.status)
      render json: { error: 'Vehicle not available for public viewing' }, status: :forbidden
      return
    end
  end
  
  # Get public statuses as array, handling different storage formats
  def get_public_statuses
    statuses = @company.public_statuses
    
    # Handle nil - default to ['available']
    return ['available'] if statuses.nil?
    
    # Handle string (JSON string)
    if statuses.is_a?(String)
      begin
        parsed = JSON.parse(statuses)
        return parsed.is_a?(Array) ? parsed : [statuses]
      rescue JSON::ParserError
        return [statuses]
      end
    end
    
    # Handle array
    return statuses if statuses.is_a?(Array)
    
    # Fallback
    ['available']
  end
  
  # Get items per page setting, handling different storage formats
  def get_items_per_page
    per_page = @company.items_per_page
    return 12 if per_page.nil?
    
    per_page.is_a?(Integer) ? per_page : per_page.to_i
  rescue
    12
  end
  
  # Get boolean setting from JSONB store
  def get_boolean_setting(setting_name, default = true)
    value = @company.public_send(setting_name)
    return default if value.nil?
    
    # Handle string "true"/"false"
    return true if value.to_s.downcase == 'true'
    return false if value.to_s.downcase == 'false'
    
    # Handle boolean
    !!value
  rescue
    default
  end
  
  # Get string setting from JSONB store
  def get_string_setting(setting_name, default = nil)
    value = @company.public_send(setting_name)
    value.presence || default
  rescue
    default
  end
  
  # Format status label for display (convert underscores to title case)
  def format_status_label(status)
    return nil if status.blank?
    
    status.to_s
          .split('_')
          .map(&:capitalize)
          .join(' ')
  end
  
  # Resolve branding with Location → Company → Platform hierarchy
  def resolve_branding(location = nil)
    # Start with platform defaults
    branding = {
      primary_color: '#3b82f6',    # Default blue
      secondary_color: '#9BA946',  # Default green
      logo_url: nil,
      company_name: @company.name
    }
    
    # Apply company branding if available (stored in branding_settings JSONB)
    if @company.branding_settings.present?
      settings = @company.branding_settings
      
      if settings['primaryColor'].present?
        branding[:primary_color] = settings['primaryColor']
      end
      
      if settings['secondaryColor'].present?
        branding[:secondary_color] = settings['secondaryColor']
      end
      
      if settings['logo'].present?
        branding[:logo_url] = settings['logo']
      end
    end
    
    # Apply location branding if location specified (highest priority)
    # Locations also use branding_settings JSONB column
    if location.present? && location.branding_settings.present?
      settings = location.branding_settings
      
      if settings['primaryColor'].present?
        branding[:primary_color] = settings['primaryColor']
      end
      
      if settings['secondaryColor'].present?
        branding[:secondary_color] = settings['secondaryColor']
      end
      
      if settings['logo'].present?
        branding[:logo_url] = settings['logo']
      end
    end
    
    branding
  end
  
  # JSON for vehicle list view (lighter payload)
  def vehicle_list_json(vehicle)
    # Determine which price to display (prefer sale_price)
    # NOTE: Prices are stored as decimal dollars, not cents
    display_price = if vehicle.sale_price.present? && vehicle.sale_price > 0
      { 
        amount: vehicle.sale_price.to_f.round(2),
        type: 'sale'
      }
    elsif vehicle.rent_price.present? && vehicle.rent_price > 0
      { 
        amount: vehicle.rent_price.to_f.round(2),
        type: 'rent'
      }
    else
      nil
    end
    
    {
      id: vehicle.id,
      inventory_id: vehicle.inventory_id,
      listing_type: vehicle.listing_type,
      location_id: vehicle.location_id,  # CRITICAL: For lead assignment
      status: vehicle.status,
      status_label: format_status_label(vehicle.status),
      
      # Basic info
      year: vehicle.year,
      make: vehicle.make,
      model: vehicle.model,
      trim: vehicle.trim,
      
      # Pricing - default to sale_price, fallback to rent_price
      price: display_price&.dig(:amount),
      price_type: display_price&.dig(:type),
      sale_price: vehicle.sale_price&.to_f&.round(2),
      rent_price: vehicle.rent_price&.to_f&.round(2),
      
      # Specifications
      mileage: vehicle.mileage,
      condition: vehicle.condition,
      
      # Manufactured home fields
      bedrooms: vehicle.bedrooms,
      bathrooms: vehicle.bathrooms,
      square_feet: vehicle.square_feet,
      sections: vehicle.sections,
      
      # RV fields
      rv_class: vehicle.rv_class,
      length: vehicle.length,
      weight: vehicle.weight,
      slideouts: vehicle.slideouts,
      
      # Location
      location_city: vehicle.location&.city,
      location_state: vehicle.location&.state,
      
      # Images (using database column - it's a JSON array)
      primary_image_url: vehicle.images&.first,
      image_urls: vehicle.images || [],
      floor_plan_images: vehicle.floor_plan_images || [],
      
      # Media flags for list view icons
      has_virtual_tour: vehicle.virtual_tour_url.present?,
      has_video: vehicle.video_url.present?,
      
      # Timestamps
      created_at: vehicle.created_at,
      updated_at: vehicle.updated_at,
      
      # Computed fields
      display_name: "#{vehicle.year} #{vehicle.make} #{vehicle.model}".strip,
      full_location: [vehicle.location_city, vehicle.location_state].compact.join(', '),
      identifier: vehicle.inventory_id || "ID-#{vehicle.id}"
    }
  end
  
  # JSON for vehicle detail view (full payload)
  def vehicle_detail_json(vehicle)
    # Include all list fields plus additional details
    vehicle_list_json(vehicle).merge(
      # Full description
      description: vehicle.description,
      features: vehicle.features || [],
      
      # Media links
      virtual_tour_url: vehicle.virtual_tour_url,
      video_url: vehicle.video_url,
      floor_plan_images: vehicle.floor_plan_images || [],
      
      # Identifiers
      vin: vehicle.vin,
      serial_number: vehicle.serial_number,
      stock_number: vehicle.stock_number,
      color: vehicle.color,
      
      # Manufactured Home Type
      home_type: vehicle.home_type,
      
      # Location details
      location_type: vehicle.location_type,
      community_name: vehicle.community_name,
      community_key: vehicle.community_key,
      address1: vehicle.address1,
      county_name: vehicle.county_name,
      
      # Dimensions
      width2: vehicle.width2,
      length2: vehicle.length2,
      width3: vehicle.width3,
      length3: vehicle.length3,
      
      # Construction Materials
      exterior_material: vehicle.exterior_material,
      roof_material: vehicle.roof_material,
      flooring_type: vehicle.flooring_type,
      insulation_type: vehicle.insulation_type,
      ceiling_type: vehicle.ceiling_type,
      wall_type: vehicle.wall_type,
      
      # Amenities & Features (boolean flags)
      fireplace: vehicle.fireplace,
      garage: vehicle.garage,
      carport: vehicle.carport,
      deck: vehicle.deck,
      patio: vehicle.patio,
      central_air: vehicle.central_air,
      cathedral_ceiling: vehicle.cathedral_ceiling,
      ceiling_fan: vehicle.ceiling_fan,
      skylight: vehicle.skylight,
      walkin_closet: vehicle.walkin_closet,
      laundry_room: vehicle.laundry_room,
      pantry: vehicle.pantry,
      sun_room: vehicle.sun_room,
      basement: vehicle.basement,
      has_storage: vehicle.has_storage,
      garden_tub: vehicle.garden_tub,
      garbage_disposal: vehicle.garbage_disposal,
      refrigerator: vehicle.refrigerator,
      microwave: vehicle.microwave,
      oven: vehicle.oven,
      dishwasher: vehicle.dishwasher,
      clothes_washer: vehicle.clothes_washer,
      clothes_dryer: vehicle.clothes_dryer,
      gutters: vehicle.gutters,
      shutters: vehicle.shutters,
      thermopane: vehicle.thermopane,
      
      # Detailed specs
      fuel_type: vehicle.fuel_type,
      engine_type: vehicle.engine_type,
      transmission: vehicle.transmission,
      
      # RV amenities (only include if columns exist)
      fresh_water_capacity: vehicle.fresh_water_capacity,
      gray_water_capacity: vehicle.gray_water_capacity,
      black_water_capacity: vehicle.black_water_capacity,
      awning: vehicle.awning,
      
      # Manufactured home details
      roof_type: vehicle.roof_type,
      siding_type: vehicle.siding_type,
      
      # Full address (if location available)
      location_street: vehicle.location&.address_line1,
      location_city: vehicle.location&.city,
      location_state: vehicle.location&.state,
      location_zip: vehicle.location&.zip_code,
      location_phone: vehicle.location&.phone,
      location_email: vehicle.location&.email
    )
  end
end
