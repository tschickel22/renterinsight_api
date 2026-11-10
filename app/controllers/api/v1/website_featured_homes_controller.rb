# frozen_string_literal: true

# The homes a dealer picks for a website's Featured Homes section.
#
# The editor saves the whole list at once (order, title, description), so
# there is one read and one replace rather than per-row create/update/delete
# and a separate reorder call.
#
# The title and description are the website's own copy and never write back
# to the vehicle. Blank means "show the inventory's description".
#
# Pricing and sale are different: they ARE the inventory record. A row's
# `pricing` (price, sale on/off, discount, start and end days, callout) is
# written to the home itself, so the inventory screen, other sites and the
# deal sheet all see the same sale. Needs inventory update permission.
# `show_sale` is the site's own switch: show this home's sale on this site.
class Api::V1::WebsiteFeaturedHomesController < ApplicationController
  before_action :set_company_scope
  before_action :set_website

  MAX_FEATURED = 24

  # GET /api/v1/websites/:website_id/featured_homes
  def index
    return unless authorize_action!('websites', 'read')

    render json: index_json
  end

  # PUT /api/v1/websites/:website_id/featured_homes
  # Params: featured_homes: [{ vehicle_id, title, description }, ...] in display order
  #         settings: { display_count, rotation } (optional; off | visit | day | week)
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

    pricing_rows = rows.select { |r| r[:pricing].present? }
    if pricing_rows.any? && !can?('inventory', 'update')
      return render json: { error: 'You need permission to edit inventory to change prices or sales.' }, status: :forbidden
    end

    ActiveRecord::Base.transaction do
      pricing_rows.each do |row|
        vehicle = vehicles[row[:vehicle_id].to_i]
        vehicle.assign_attributes(pricing_attributes(row[:pricing]))
        vehicle.save! if vehicle.changed?
      end
      if params.key?(:settings)
        @website.update!(featured_homes_settings: WebsiteFeaturedHome.normalize_settings(params[:settings].permit(:display_count, :rotation)))
      end
      @website.featured_homes.delete_all
      rows.uniq { |r| r[:vehicle_id].to_i }.each_with_index do |row, index|
        @website.featured_homes.create!(
          vehicle: vehicles[row[:vehicle_id].to_i],
          position: index,
          title: row[:title].to_s.strip.presence,
          description: row[:description].to_s.strip.presence,
          show_sale: ActiveModel::Type::Boolean.new.cast(row[:show_sale]) || false
        )
      end
    end

    render json: index_json
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  PRICING_FIELDS = %w[msrp special_discount_enabled discount_type discount_value
                      special_discount_starts_on special_discount_ends_on overlay_text].freeze

  # Only the fields sent are changed. Blank dates clear (an open-ended sale).
  def pricing_attributes(raw)
    raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    raw.stringify_keys.slice(*PRICING_FIELDS).to_h do |key, value|
      value = value.presence if value.is_a?(String)
      value = value.to_s.squish.first(60).presence if key == 'overlay_text'
      [key, value]
    end
  end

  def set_website
    # CRITICAL: Always use @company scope
    @website = @company.websites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def index_json
    {
      items: featured_scope.map { |f| featured_json(f) },
      settings: WebsiteFeaturedHome.normalize_settings(@website.featured_homes_settings),
      # Whether any page has a Featured Homes section, so the editor shows
      # the picker only to a site that uses it.
      in_use: @website.website_pages.where(is_deleted: [false, nil]).any? do |page|
        Array(page.blocks).any? { |b| %w[featuredHomes featured_homes].include?(b.is_a?(Hash) ? b['type'] : nil) }
      end
    }
  end

  def featured_scope
    @website.featured_homes.includes(vehicle: :inventory_packages)
  end

  def featured_json(featured)
    vehicle = featured.vehicle
    {
      id: featured.id,
      vehicle_id: vehicle.id,
      position: featured.position,
      title: featured.title,
      description: featured.description,
      show_sale: featured.show_sale,
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
        # The home's pricing and sale, as inventory holds them.
        pricing: {
          msrp: vehicle.msrp&.to_f,
          package_total: vehicle.inventory_packages.select(&:include_in_total).sum { |p| p.price.to_f },
          special_discount_enabled: !!vehicle.special_discount_enabled,
          discount_type: vehicle.discount_type,
          discount_value: vehicle.discount_value&.to_f,
          discounted_price: vehicle.discounted_price&.to_f,
          special_discount_starts_on: vehicle.special_discount_starts_on&.iso8601,
          special_discount_ends_on: vehicle.special_discount_ends_on&.iso8601,
          overlay_text: vehicle.overlay_text
        },
        # What the site would show for the sale today (nil: not running).
        sale_now: WebsiteFeaturedHome.sale_json(vehicle),
        primary_image_url: first_image_url(vehicle.images)
      }
    }
  end

  def first_image_url(images)
    first = Array(images).first
    first.is_a?(Hash) ? (first['url'] || first[:url]) : first
  end
end
