# frozen_string_literal: true

# Public::LandParcelsController - Public land parcel catalog API
# Authentication: Token-based (public_inventory_token) - same token as vehicles
#
# Endpoints:
# - GET /public/land_parcels - List land parcels with filtering/pagination
# - GET /public/land_parcels/:id - Single land parcel details
# - GET /public/land_parcels/filters - Available filter options
class Public::LandParcelsController < ApplicationController
  skip_before_action :authenticate, raise: false
  skip_before_action :set_company_scope, raise: false
  skip_before_action :set_current_attributes, raise: false

  before_action :authenticate_inventory_token
  before_action :check_public_inventory_enabled
  before_action :set_land_parcel, only: [:show]

  # GET /public/land_parcels
  def index
    statuses = if params[:statuses].present?
      params[:statuses].split(',').map(&:strip)
    else
      ['available']
    end

    @parcels = @company.land_parcels
                       .where(status: statuses)
                       .where(is_deleted: [false, nil])

    # Price filtering
    @parcels = @parcels.where('price >= ?', params[:min_price].to_f) if params[:min_price].present?
    @parcels = @parcels.where('price <= ?', params[:max_price].to_f) if params[:max_price].present?

    # Acreage filtering
    @parcels = @parcels.where('acreage >= ?', params[:min_acreage].to_f) if params[:min_acreage].present?
    @parcels = @parcels.where('acreage <= ?', params[:max_acreage].to_f) if params[:max_acreage].present?

    # Zoning
    @parcels = @parcels.where(zoning_type: params[:zoning_type]) if params[:zoning_type].present?

    # Location filters
    @parcels = @parcels.where('city ILIKE ?', params[:city]) if params[:city].present?
    @parcels = @parcels.where(state: params[:state]) if params[:state].present?
    @parcels = @parcels.where('county ILIKE ?', params[:county]) if params[:county].present?

    # Search
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      @parcels = @parcels.where(
        "parcel_number ILIKE ? OR name ILIKE ? OR address ILIKE ? OR city ILIKE ? OR county ILIKE ? OR description ILIKE ?",
        search_term, search_term, search_term, search_term, search_term, search_term
      )
    end

    # Sorting
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    allowed_sort_fields = %w[created_at price acreage price_per_acre city state]
    sort_by = 'created_at' unless allowed_sort_fields.include?(sort_by)
    @parcels = @parcels.order(sort_by => sort_order)

    # Pagination
    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 12).to_i, 50].min
    total_count = @parcels.count
    total_pages = (total_count.to_f / per_page).ceil
    @parcels = @parcels.offset((page - 1) * per_page).limit(per_page)

    # Branding
    branding = resolve_branding

    render json: {
      items: @parcels.map { |p| parcel_list_json(p) },
      meta: {
        total: total_count,
        page: page,
        per_page: per_page,
        total_pages: total_pages,
        company: { id: @company.id, name: @company.name },
        branding: branding
      }
    }
  end

  # GET /public/land_parcels/:id
  def show
    branding = resolve_branding

    render json: {
      parcel: parcel_detail_json(@parcel),
      company: {
        name: @company.name
      },
      branding: branding
    }
  end

  # GET /public/land_parcels/filters
  def filters
    statuses = if params[:statuses].present?
      params[:statuses].split(',').map(&:strip)
    else
      ['available']
    end

    parcels = @company.land_parcels
                      .where(status: statuses)
                      .where(is_deleted: [false, nil])

    zoning_types = parcels.where.not(zoning_type: [nil, '']).distinct.pluck(:zoning_type).compact.sort
    cities = parcels.where.not(city: [nil, '']).distinct.pluck(:city).compact.sort
    states = parcels.where.not(state: [nil, '']).distinct.pluck(:state).compact.sort
    counties = parcels.where.not(county: [nil, '']).distinct.pluck(:county).compact.sort
    statuses_available = parcels.where.not(status: [nil, '']).distinct.pluck(:status).compact.sort

    prices = parcels.where.not(price: nil).pluck(:price).map(&:to_f)
    price_range = prices.any? ? { min: prices.min.round(2), max: prices.max.round(2) } : { min: 0, max: 0 }

    acreages = parcels.where.not(acreage: nil).pluck(:acreage).map(&:to_f)
    acreage_range = acreages.any? ? { min: acreages.min.round(4), max: acreages.max.round(4) } : { min: 0, max: 0 }

    render json: {
      zoning_types: zoning_types,
      cities: cities,
      states: states,
      counties: counties,
      statuses: statuses_available,
      price_range: price_range,
      acreage_range: acreage_range,
      total_count: parcels.count
    }
  end

  private

  def authenticate_inventory_token
    token = params[:token] || request.headers['X-Inventory-Token']
    unless token.present?
      render json: { error: 'Missing inventory token' }, status: :unauthorized and return
    end
    @company = Company.find_by(public_inventory_token: token)
    unless @company
      render json: { error: 'Invalid inventory token' }, status: :unauthorized and return
    end
  end

  def check_public_inventory_enabled
    unless @company.public_inventory_enabled
      render json: { error: 'Public inventory access is disabled' }, status: :forbidden and return
    end
  end

  def set_land_parcel
    @parcel = @company.land_parcels.find_by(id: params[:id])
    unless @parcel
      render json: { error: 'Land parcel not found' }, status: :not_found and return
    end
    if @parcel.is_deleted
      render json: { error: 'Land parcel no longer available' }, status: :gone and return
    end
    statuses = params[:statuses].present? ? params[:statuses].split(',').map(&:strip) : ['available']
    unless statuses.include?(@parcel.status)
      render json: { error: 'Land parcel not available for public viewing' }, status: :forbidden and return
    end
  end

  def resolve_branding
    branding = {
      primary_color: '#3b82f6',
      secondary_color: '#9BA946',
      logo_url: nil,
      company_name: @company.name
    }
    if @company.branding_settings.present?
      settings = @company.branding_settings
      branding[:primary_color] = settings['primaryColor'] if settings['primaryColor'].present?
      branding[:secondary_color] = settings['secondaryColor'] if settings['secondaryColor'].present?
      branding[:logo_url] = settings['logo'] if settings['logo'].present?
    end
    branding
  end

  def format_status_label(status)
    return nil if status.blank?
    status.to_s.split('_').map(&:capitalize).join(' ')
  end

  def parcel_list_json(parcel)
    {
      id: parcel.id,
      type: 'land',  # Distinguishes from vehicles in combined views
      parcel_number: parcel.parcel_number,
      name: parcel.name,
      display_name: parcel.display_name,
      status: parcel.status,
      status_label: format_status_label(parcel.status),
      zoning_type: parcel.zoning_type,
      acreage: parcel.acreage&.to_f,
      price: parcel.price&.to_f,
      price_per_acre: parcel.price_per_acre&.to_f,
      address: parcel.address,
      city: parcel.city,
      state: parcel.state,
      zip: parcel.zip,
      county: parcel.county,
      full_address: parcel.full_address,
      images: parcel.images || [],
      has_coordinates: parcel.latitude.present? && parcel.longitude.present?,
      created_at: parcel.created_at,
      updated_at: parcel.updated_at
    }
  end

  def parcel_detail_json(parcel)
    parcel_list_json(parcel).merge(
      description: parcel.description,
      features: parcel.features || [],
      utilities: parcel.utilities || {},
      latitude: parcel.latitude&.to_f,
      longitude: parcel.longitude&.to_f,
      owner_name: nil,  # Don't expose owner info publicly
      documents: [],     # Don't expose documents publicly
      notes: nil         # Don't expose internal notes publicly
    )
  end
end
