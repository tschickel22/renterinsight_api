# frozen_string_literal: true

# Land + home packages for a dealer's website: a lot and a home offered
# together at one price. Authorised like the rest of the public catalog, by
# the company's public inventory token.
#
# Only packages switched on for the website, whose lot is still available and
# whose home is still for sale. A package whose lot or home sells drops off on
# its own, with nobody having to remember it.
class Public::LandHomePackagesController < ApplicationController
  skip_before_action :authenticate, raise: false
  skip_before_action :set_company_scope, raise: false
  skip_before_action :set_current_attributes, raise: false

  before_action :authenticate_inventory_token
  before_action :check_public_inventory_enabled

  DEFAULT_HOME_STATUSES = %w[available available_to_order].freeze

  # GET /public/land_home_packages?token=&statuses=&limit=
  def index
    home_statuses = params[:statuses].present? ? params[:statuses].split(',').map(&:strip) : DEFAULT_HOME_STATUSES
    limit = (params[:limit] || 24).to_i.clamp(1, 48)

    packages = @company.land_home_packages
                       .includes(:land_parcel, :vehicle)
                       .where(show_on_website: true)
                       .ordered
                       .select { |p| p.offerable?(home_statuses) }
                       .first(limit)

    render json: { items: packages.map { |p| package_json(p) }, meta: { total: packages.size } }
  end

  private

  def authenticate_inventory_token
    token = params[:token] || request.headers['X-Inventory-Token']
    return render(json: { error: 'Missing inventory token' }, status: :unauthorized) if token.blank?

    @company = Company.find_by(public_inventory_token: token)
    render json: { error: 'Invalid inventory token' }, status: :unauthorized unless @company
  end

  def check_public_inventory_enabled
    return if @company.public_inventory_enabled

    render json: { error: 'Public inventory access is disabled' }, status: :forbidden
  end

  def package_json(package)
    parcel = package.land_parcel
    vehicle = package.vehicle
    home_images = image_urls(vehicle.images)
    lot_images = image_urls(parcel.images)
    {
      id: package.id,
      title: package.display_name,
      price: package.price&.to_f,
      description: package.description,
      images: (home_images.first(1) + lot_images.first(1) + home_images.drop(1).first(4)).compact,
      home: {
        id: vehicle.id,
        display_name: package.vehicle_name,
        bedrooms: vehicle.bedrooms,
        bathrooms: vehicle.bathrooms&.to_f,
        square_feet: vehicle.square_feet,
        sections: vehicle.sections,
        image: home_images.first,
      },
      land: {
        id: parcel.id,
        display_name: parcel.display_name,
        acreage: parcel.acreage&.to_f,
        city: parcel.city,
        state: parcel.state,
        county: parcel.county,
        zoning_type: parcel.zoning_type,
        image: lot_images.first,
      },
    }
  end

  # Inventory stores photos as plain URLs or { url: } hashes; a parcel's own
  # uploads can be paths on this API, which a visitor's browser needs whole.
  def image_urls(images)
    Array(images).filter_map do |img|
      url = (img.is_a?(Hash) ? (img['url'] || img[:url]) : img).to_s.strip
      next if url.blank?

      url.match?(%r{\A(https?|data):}) ? url : "#{request.base_url}/#{url.delete_prefix('/')}"
    end
  end
end
