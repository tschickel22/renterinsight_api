# frozen_string_literal: true

# Builds an HTML "Homes You Might Like" block for nurture/campaign emails.
# Each vehicle card and the catalog CTA use TrackedLinks so click attribution
# back to the vehicle, source, and entity is automatic.
class InventoryEmailBlockBuilder
  def initialize(company:, entity:, vehicles:, source_type: nil, source_id: nil)
    @company              = company
    @entity               = entity
    @vehicles             = Array(vehicles)
    @source_type          = source_type
    @source_id            = source_id
    @created_tracked_links = []
  end

  def build_html
    return '' if @vehicles.empty?

    cards         = @vehicles.map { |v| build_vehicle_card(v) }
    catalog_link  = build_catalog_tracked_link

    html  = '<div style="margin: 20px 0; padding: 16px 0; border-top: 1px solid #e5e7eb;">'
    html += '<h3 style="font-size: 18px; font-weight: 600; margin-bottom: 12px; color: #1f2937;">Homes You Might Like</h3>'
    html += cards.join('')

    if catalog_link
      html += '<div style="text-align: center; margin-top: 16px;">'
      html += %(<a href="#{catalog_link.tracking_url}" style="display: inline-block; padding: 10px 24px; background-color: #C44C3D; color: white; text-decoration: none; border-radius: 6px; font-weight: 500;">View More Homes</a>)
      html += '</div>'
    end

    html += '</div>'
    html
  end

  def tracked_link_ids
    @created_tracked_links.map(&:id)
  end

  private

  def build_vehicle_card(vehicle)
    tl = TrackedLink.create_for_inventory!(
      company:     @company,
      vehicle:     vehicle,
      url:         build_public_inventory_url(vehicle),
      entity_type: @entity.class.name,
      entity_id:   @entity.id,
      source_type: @source_type,
      source_id:   @source_id
    )
    @created_tracked_links << tl

    image_url = extract_primary_image(vehicle)
    title     = [vehicle.year, vehicle.make, vehicle.model].compact.join(' ')

    specs = []
    specs << "#{vehicle.bedrooms} bed"    if vehicle.bedrooms.present?    && vehicle.bedrooms.to_i  > 0
    specs << "#{vehicle.bathrooms} bath"  if vehicle.bathrooms.present?   && vehicle.bathrooms.to_f > 0
    specs << "#{vehicle.square_feet} sqft" if vehicle.square_feet.present? && vehicle.square_feet.to_i > 0

    price = vehicle.sale_price.present? ? number_to_currency(vehicle.sale_price) : 'Contact for Price'

    safe_title = ERB::Util.html_escape(title)

    card  = '<div style="margin-bottom: 16px; border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden;">'
    if image_url
      card += %(<a href="#{tl.tracking_url}" style="display: block;"><img src="#{image_url}" alt="#{safe_title}" style="width: 100%; height: 200px; object-fit: cover;" /></a>)
    end
    card += '<div style="padding: 12px;">'
    card += %(<h4 style="font-size: 16px; font-weight: 600; margin: 0 0 4px;">#{safe_title}</h4>)
    card += %(<p style="font-size: 14px; color: #6b7280; margin: 0 0 8px;">#{ERB::Util.html_escape(specs.join(' • '))}</p>)
    card += %(<p style="font-size: 18px; font-weight: 700; color: #C44C3D; margin: 0 0 12px;">#{ERB::Util.html_escape(price)}</p>)
    card += %(<a href="#{tl.tracking_url}" style="display: inline-block; padding: 8px 16px; background-color: #34495E; color: white; text-decoration: none; border-radius: 4px; font-size: 14px;">View Details</a>)
    card += '</div></div>'
    card
  end

  def build_catalog_tracked_link
    token = @company.try(:public_inventory_token)
    return nil if token.blank?

    tl = TrackedLink.create!(
      company:     @company,
      url:         "#{public_base_url}/public/#{token}/inventory",
      link_type:   'inventory_catalog',
      entity_type: @entity.class.name,
      entity_id:   @entity.id,
      source_type: @source_type,
      source_id:   @source_id
    )
    @created_tracked_links << tl
    tl
  end

  def build_public_inventory_url(vehicle)
    token = @company.try(:public_inventory_token)
    return '#' if token.blank?
    "#{public_base_url}/public/#{token}/inventory/#{vehicle.id}"
  end

  def public_base_url
    # DMS frontend URL — check company-specific setting first, then env vars
    @company.try(:dms_frontend_url).presence ||
      ENV['DMS_FRONTEND_URL'].presence ||
      ENV['FRONTEND_URL'].presence ||
      'https://staging-dms.renterinsight.com'
  end

  def extract_primary_image(vehicle)
    images = vehicle.images
    return nil if images.blank?

    parsed = images.is_a?(String) ? (JSON.parse(images) rescue nil) : images
    return nil unless parsed.is_a?(Array) && parsed.any?
    parsed.first.is_a?(Hash) ? parsed.first['url'] : parsed.first
  end

  def number_to_currency(amount)
    return '$0' unless amount
    '$' + amount.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
end
