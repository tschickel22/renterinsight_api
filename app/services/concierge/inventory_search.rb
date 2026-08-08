# frozen_string_literal: true

module Concierge
  # Runs a parsed home search against the dealer's own stock.
  #
  # Scoped to exactly what the public inventory grid serves, so the concierge can
  # never surface a home the site itself would refuse to show. A chat that offers
  # a sold home is worse than a chat that offers nothing.
  class InventorySearch
    SERVABLE = %w[available available_to_order].freeze
    LIMIT = 4

    def initialize(company:, filters: {})
      @company = company
      @filters = (filters || {}).symbolize_keys
    end

    def call
      return [] if @company.nil?

      scope = base_scope
      scope = scope.where(bedrooms: @filters[:bedrooms]) if @filters[:bedrooms].present?
      scope = scope.where('bathrooms >= ?', @filters[:bathrooms].to_f) if @filters[:bathrooms].present?
      scope = scope.where('square_feet >= ?', @filters[:square_feet_min].to_i) if @filters[:square_feet_min].present?
      scope = scope.where('sale_price <= ?', @filters[:max_price].to_i) if @filters[:max_price].present?
      scope = scope.where('sale_price >= ?', @filters[:min_price].to_i) if @filters[:min_price].present?

      # A price filter is meaningless against a home with no price, and showing
      # one anyway reads as ignoring what the visitor asked for.
      scope = scope.where.not(sale_price: nil) if @filters[:max_price].present? || @filters[:min_price].present?

      scope.limit(LIMIT).map { |vehicle| present(vehicle) }
    rescue StandardError => e
      Rails.logger.warn("[Concierge::InventorySearch] #{e.class}: #{e.message}")
      []
    end

    private

    def base_scope
      @company.vehicles.where(is_deleted: [false, nil], status: SERVABLE).order(updated_at: :desc)
    end

    # Carries its own URL, so the answer is a link to the home rather than a
    # description of it.
    def present(vehicle)
      {
        id: vehicle.id,
        name: [vehicle.year, vehicle.make, vehicle.model].compact_blank.join(' '),
        price: vehicle.sale_price&.to_i,
        bedrooms: vehicle.bedrooms,
        bathrooms: vehicle.bathrooms,
        square_feet: vehicle.square_feet,
        image: vehicle.public_image_urls.first,
        path: Websites::HomeUrl.path_for(vehicle)
      }
    end
  end
end
