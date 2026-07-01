# frozen_string_literal: true

# Shared serializer for a Vehicle in "brochure format" — the JSON shape the
# frontend brochure renderer expects (images[], features[], amenities{}, packages).
#
# Two consumers today:
#   * Api::V1::BrochuresController#public_view (customer-facing brochure)
#   * Api::V1::DealDeskSharesController (customer-facing scenario share)
#
# One shape means the same layout code on the frontend can render both without
# drift. Any addition here reaches both surfaces.
module VehicleBrochureJson
  extend ActiveSupport::Concern

  private

  def vehicle_brochure_payload(vehicle)
    return nil unless vehicle

    base_url = if request.ssl?
      "https://#{request.host}#{":#{request.port}" unless [80, 443].include?(request.port)}"
    else
      "http://#{request.host}#{":#{request.port}" unless [80, 443].include?(request.port)}"
    end

    full_image_urls = (vehicle.images || []).map do |entry|
      url = _brochure_image_url_from(entry)
      next nil if url.blank?
      url.start_with?('http') ? url : "#{base_url}#{url}"
    end.compact

    {
      id: vehicle.id.to_s,
      inventoryId: vehicle.inventory_id,
      listingType: vehicle.listing_type,
      year: vehicle.year,
      make: vehicle.make,
      model: vehicle.model,
      trim: vehicle.trim,
      displayName: vehicle.display_name,
      condition: vehicle.condition,
      color: vehicle.color,
      stockNumber: vehicle.stock_number,
      status: vehicle.status,
      salePrice: vehicle.sale_price&.to_f,
      rentPrice: vehicle.rent_price&.to_f,
      msrp: vehicle.msrp&.to_f,
      description: vehicle.description,
      features: vehicle.features || [],
      images: full_image_urls,
      floorPlanImages: (vehicle.floor_plan_images || []).map { |entry|
        url = _brochure_image_url_from(entry)
        next nil if url.blank?
        url.start_with?('http') ? url : "#{base_url}#{url}"
      }.compact,
      videoUrl: vehicle.video_url,
      virtualTourUrl: vehicle.virtual_tour_url,
      location: {
        street: vehicle.address1,
        city: vehicle.location_city,
        state: vehicle.location_state,
        zip: vehicle.location_zip
      },
      bedrooms: vehicle.bedrooms,
      bathrooms: vehicle.bathrooms,
      squareFootage: vehicle.square_feet,
      sleeps: vehicle.sleeps,
      length: vehicle.length,
      width: vehicle.width,
      sections: vehicle.sections,
      homeType: vehicle.home_type,
      vin: vehicle.vin,
      serialNumber: vehicle.serial_number,
      inventoryPackages: (vehicle.inventory_packages&.ordered || []).map { |pkg|
        {
          id: pkg.id,
          name: pkg.name,
          description: pkg.description,
          price: pkg.price&.to_f,
          includeInTotal: pkg.include_in_total,
          showPriceInMarketing: pkg.show_price_in_marketing
        }
      },
      totalHomePrice: vehicle.respond_to?(:total_home_price) ? vehicle.total_home_price : vehicle.sale_price&.to_f
    }
  end

  def _brochure_image_url_from(entry)
    case entry
    when Hash then entry['url'] || entry[:url]
    when String then entry
    else nil
    end
  end
end
