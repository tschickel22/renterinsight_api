# frozen_string_literal: true

# The homes a dealer picks for a website's Featured Homes section.
#
# The editor saves the whole list at once (order, title, description), so
# there is one read and one replace rather than per-row create/update/delete
# and a separate reorder call.
#
# The title and description are the website's own copy and never write back
# to the vehicle. Blank means "show the inventory's description".
class Api::V1::WebsiteFeaturedHomesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website

  MAX_FEATURED = 24

  # GET /api/v1/websites/:website_id/featured_homes
  def index
    return unless authorize_action!('websites', 'read')

    render json: { items: featured_scope.map { |f| featured_json(f) } }
  end

  # PUT /api/v1/websites/:website_id/featured_homes
  # Params: featured_homes: [{ vehicle_id, title, description }, ...] in display order
  def replace
    return unless authorize_action!('websites', 'update')

    rows = Array(params[:featured_homes]).first(MAX_FEATURED)
    vehicle_ids = rows.map { |r| r[:vehicle_id].to_i }

    # CRITICAL: only this company's homes can be featured.
    vehicles = @company.vehicles.where(id: vehicle_ids).index_by(&:id)
    missing = vehicle_ids.uniq - vehicles.keys
    if missing.any?
      return render json: { error: "Homes not found: #{missing.join(', ')}" }, status: :unprocessable_entity
    end

    ActiveRecord::Base.transaction do
      @website.featured_homes.delete_all
      rows.uniq { |r| r[:vehicle_id].to_i }.each_with_index do |row, index|
        @website.featured_homes.create!(
          vehicle: vehicles[row[:vehicle_id].to_i],
          position: index,
          title: row[:title].to_s.strip.presence,
          description: row[:description].to_s.strip.presence
        )
      end
    end

    render json: { items: featured_scope.map { |f| featured_json(f) } }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_website
    # CRITICAL: Always use @company scope
    @website = @company.websites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def featured_scope
    @website.featured_homes.includes(:vehicle)
  end

  def featured_json(featured)
    vehicle = featured.vehicle
    {
      id: featured.id,
      vehicle_id: vehicle.id,
      position: featured.position,
      title: featured.title,
      description: featured.description,
      vehicle: {
        id: vehicle.id,
        display_name: [vehicle.year, vehicle.make, vehicle.model].compact.join(' '),
        stock_number: vehicle.stock_number,
        status: vehicle.status,
        is_deleted: vehicle.is_deleted,
        bedrooms: vehicle.bedrooms,
        bathrooms: vehicle.bathrooms&.to_f,
        square_feet: vehicle.square_feet,
        sale_price: vehicle.sale_price&.to_f,
        description: vehicle.description,
        primary_image_url: first_image_url(vehicle.images)
      }
    }
  end

  def first_image_url(images)
    first = Array(images).first
    first.is_a?(Hash) ? (first['url'] || first[:url]) : first
  end
end
