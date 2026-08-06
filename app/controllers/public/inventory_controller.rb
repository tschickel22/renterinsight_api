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
  # - source_filter: Listing Source scope. One of:
  #     'dealer_preferred' (recommended for public catalog) — manufacturer originals
  #        EXCEPT those the dealer has cloned/edited; plus the dealer's clones.
  #        Prevents showing the same home twice.
  #     'dealer_only'      — clones + manual entries only (hides untouched feed)
  #     'all'              — no scope applied (default if param omitted)
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
    
    # Manufactured home filters (supports: "3" exact, "1,2" IN list, "4+" minimum)
    if params[:bedrooms].present?
      bed_val = params[:bedrooms].to_s.strip
      if bed_val.end_with?('+')
        @vehicles = @vehicles.where('bedrooms >= ?', bed_val.chomp('+').to_i)
      elsif bed_val.include?(',')
        @vehicles = @vehicles.where(bedrooms: bed_val.split(',').map(&:to_i))
      else
        @vehicles = @vehicles.where(bedrooms: bed_val)
      end
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

    # Listing Source scope (Share & Embed / public catalog).
    # Mirrors the same scope names used by api/v1/vehicles_controller#index.
    # 'all' or blank → no-op (return everything that matched the other filters).
    @vehicles = apply_source_filter(@vehicles, params[:source_filter])
    
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
        branding: branding,
        champion_disclaimer: ChampionDisclaimer.for_company(@company, vehicle_scope: @vehicles)
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
    
    # Contact location resolution:
    # 1. contact_location_id param (from embed config URL) → use that specific location
    # 2. Saved embed config (fallback when no param) → check company's saved settings
    # 3. vehicle's own location → use that
    # 4. Corporate location fallback
    contact_location = if params[:contact_location_id].present?
      @company.locations.find_by(id: params[:contact_location_id], is_deleted: [false, nil])
    else
      # Check saved embed config for contact location preference
      saved_config = Setting.get('Company', @company.id, 'embed_inventory_config') rescue nil
      if saved_config.is_a?(Hash)
        mode = saved_config['contactLocationMode'] || saved_config['contact_location_mode'] || 'vehicle'
        case mode
        when 'specific'
          loc_id = saved_config['contactLocationId'] || saved_config['contact_location_id']
          @company.locations.find_by(id: loc_id, is_deleted: [false, nil]) if loc_id.present?
        when 'corporate'
          @company.locations.where(is_deleted: [false, nil], active: true, is_corporate: true).first
        else
          nil # 'vehicle' mode — fall through to vehicle's location below
        end
      end
    end
    contact_location ||= @vehicle.location
    contact_location ||= @company.locations.where(is_deleted: [false, nil], active: true, is_corporate: true).first
    contact_location ||= @company.locations.where(is_deleted: [false, nil], active: true).order(:created_at).first
    
    # Contact info - from resolved contact location
    company_data = {
      name: @company.name,
      phone: contact_location&.phone,
      email: contact_location&.email,
      address: contact_location&.address_line1,
      city: contact_location&.city,
      state: contact_location&.state,
      zip: contact_location&.zip_code,
      full_address: contact_location&.full_address,
      location_name: contact_location&.name
    }
    
    render json: {
      vehicle: vehicle_detail_json(@vehicle),
      company: company_data,
      branding: branding,
      champion_disclaimer: @vehicle.source == 'champion_ims' ? ChampionDisclaimer.for_company(@company) : { show: false }
    }
  end
  
  # GET /public/inventory/filters
  # Get available filter options (makes, models, years, locations, price ranges)
  #
  # Params:
  # - token (required): Public inventory token
  # - statuses (optional): Comma-separated statuses to scope filter options
  # - listing_type (optional): Comma-separated listing types to scope filter options
  # - source_filter (optional): Same scope as #index — keeps filter options aligned
  #     with what the catalog will actually display.
  def filters
    # Use passed statuses param if present, otherwise fall back to company defaults
    statuses = if params[:statuses].present?
      params[:statuses].split(',').map(&:strip)
    else
      get_public_statuses
    end
    
    vehicles = @company.vehicles
                      .where(status: statuses)
                      .where(is_deleted: [false, nil])
    
    # Apply listing type filter if provided (so filter options match visible vehicles)
    if params[:listing_type].present?
      listing_types = params[:listing_type].split(',').map(&:strip)
      vehicles = vehicles.where(listing_type: listing_types)
    end

    # Keep filter options in sync with what the catalog index will return for
    # the same source scope — otherwise users could see a make/year option that
    # produces zero results once selected.
    vehicles = apply_source_filter(vehicles, params[:source_filter])
    
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

  # Apply Listing Source scope. Mirrors api/v1/vehicles_controller#index.
  # Unknown / blank / 'all' values are a no-op so the public catalog stays
  # backwards-compatible with existing embeds that don't pass the param.
  # The public catalog only exposes a subset of the model scopes since
  # 'originals_only' and 'synced_only' don't make sense for end customers.
  def apply_source_filter(scope, value)
    case value.to_s
    when 'dealer_preferred' then scope.dealer_preferred
    when 'dealer_only'      then scope.dealer_only
    when 'originals_only'   then scope.originals_only  # supported for symmetry
    when 'synced_only'      then scope.synced_only     # supported for symmetry
    else                          scope                # 'all' or blank → no-op
    end
  end
  
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
    
    # Check if vehicle status is in allowed statuses
    # Accept statuses from params (block-configured) or fall back to company defaults
    statuses = if params[:statuses].present?
      params[:statuses].split(',').map(&:strip)
    else
      get_public_statuses
    end
    
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
  
  # Extract plain URL strings from images array
  # Images can be stored as [{"url"=>"https://..."}, ...] or ["https://...", ...]
  def extract_image_urls(images)
    return [] if images.blank?
    images.map { |img| img.is_a?(Hash) ? (img['url'] || img[:url]) : img }.compact
  end

  # Cached public custom field definitions (avoids N+1 on list endpoints)
  def public_custom_field_definitions
    @_public_cf_defs ||= begin
      return [] unless @company.present?
      @company.custom_fields
              .where(module: ['inventory', 'inventory_rv', 'inventory_mh'])
              .where(is_active: true)
              .where("visibility IN (?) OR visibility IS NULL", ['public', 'both'])
              .order(:section, :display_order, :created_at)
              .to_a
    end
  end

  # Get public custom fields for a specific vehicle
  def public_custom_fields_for(vehicle)
    fields = public_custom_field_definitions
    return [] if fields.empty?

    custom_values = vehicle.custom_field_values || {}

    fields.filter_map do |field|
      value = custom_values[field.field_key]
      next if value.nil? || (value.is_a?(String) && value.blank?)

      {
        key: field.field_key,
        label: field.label || field.name,
        type: field.field_type,
        value: value,
        section: field.section,
        options: field.options
      }
    end
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
      
      # Images (extract URL strings from hash objects if needed)
      primary_image_url: extract_image_urls(vehicle.images).first,
      image_urls: extract_image_urls(vehicle.images),
      floor_plan_images: extract_image_urls(vehicle.floor_plan_images),
      
      # Media flags for list view icons
      has_virtual_tour: vehicle.virtual_tour_url.present?,
      has_video: vehicle.video_url.present?,
      
      # Timestamps
      created_at: vehicle.created_at,
      updated_at: vehicle.updated_at,
      
      # Custom fields (public visibility only)
      custom_fields: public_custom_fields_for(vehicle),

      # Total price (includes add-ons and discounts)
      total_home_price: vehicle.total_home_price,

      # Estimated monthly payment, from this company's own configured rate,
      # term and minimum down payment. The frontend Vehicle type has declared
      # monthly_payment for a while but nothing ever populated it, so no card
      # could show a payment.
      #
      # Principal and interest only — see Websites::CalculatorSettings.
      monthly_payment: estimated_monthly_payment(vehicle),

      # Computed fields
      display_name: "#{vehicle.year} #{vehicle.make} #{vehicle.model}".strip,
      full_location: [vehicle.location_city, vehicle.location_state].compact.join(', '),
      identifier: vehicle.inventory_id || "ID-#{vehicle.id}"
    }
  end
  
  # Estimated monthly payment for a listing.
  #
  # Returns nil rather than 0 when it cannot be computed, so the card can hide
  # the line entirely instead of advertising "$0/mo". Suppressed when the dealer
  # has hidden pricing (a payment is a price) or turned the calculator off,
  # since a payment shown next to no price is the same disclosure by another
  # route.
  def estimated_monthly_payment(vehicle)
    return nil if @company.nil?
    return nil if @company.try(:show_pricing) == false

    @calculator_settings ||= Websites::CalculatorSettings.new(@company)
    return nil unless @calculator_settings.to_h[:enabled]

    price = vehicle.total_home_price.presence || vehicle.sale_price
    @calculator_settings.monthly_payment_for(price)
  rescue StandardError => e
    Rails.logger.warn("[Public::Inventory] monthly payment failed for vehicle #{vehicle.id}: #{e.message}")
    nil
  end

  # JSON for vehicle detail view (full payload)
  def vehicle_detail_json(vehicle)
    # Include all list fields plus additional details
    # Include inventory packages (add-ons)
    packages_data = (vehicle.inventory_packages&.ordered || []).map { |pkg|
      {
        id: pkg.id,
        name: pkg.name,
        description: pkg.description,
        price: pkg.price&.to_f,
        include_in_total: pkg.include_in_total,
        show_price_in_marketing: pkg.show_price_in_marketing,
        taxable: pkg.respond_to?(:taxable) ? (pkg.taxable || false) : false
      }
    }

    vehicle_list_json(vehicle).merge(
      # Total price with add-ons and discounts
      total_home_price: vehicle.total_home_price,
      # Pre-discount total (base + packages before any discount)
      total_price_before_discount: (vehicle.msrp || vehicle.sale_price || 0).to_f + (vehicle.inventory_packages&.where(include_in_total: true)&.sum(:price) || 0).to_f,
      msrp: vehicle.msrp&.to_f,
      special_discount_enabled: vehicle.respond_to?(:special_discount_enabled) ? vehicle.special_discount_enabled : false,
      discount_type: vehicle.respond_to?(:discount_type) ? vehicle.discount_type : nil,
      discount_value: vehicle.respond_to?(:discount_value) ? vehicle.discount_value : nil,
      discounted_price: vehicle.respond_to?(:discounted_price) ? vehicle.discounted_price&.to_f : nil,
      inventory_packages: packages_data,

      # Full description
      description: vehicle.description,
      features: vehicle.features || [],
      
      # Media links
      virtual_tour_url: vehicle.virtual_tour_url,
      video_url: vehicle.video_url,
      floor_plan_images: extract_image_urls(vehicle.floor_plan_images),
      
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
