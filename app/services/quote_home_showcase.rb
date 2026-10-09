# frozen_string_literal: true

# The home on a quote (backlog E73), when the rep chose to show it: photos,
# floor plans and the facts a buyer compares, never a price. The lot home's
# own photos when it has them, else its catalog model's; for a home to be
# built from the Deal Sheet, the model's.
class QuoteHomeShowcase
  def self.for(quote) = new(quote).call

  def initialize(quote)
    @quote = quote
    @vehicle = quote.vehicle
    @build = quote.deal_home_build || quote.deal&.home_build
    @variant = @vehicle&.catalog_plan_variant || @build&.variant
  end

  # => Hash, or nil when there is no home or nothing to show.
  def call
    return nil unless @vehicle || @variant

    photos = urls(@vehicle&.images).presence || catalog('photos')
    plans = urls(@vehicle&.floor_plan_images).presence || catalog('floor_plans')
    facts = {
      'title' => title, 'model_number' => @variant&.model_number,
      'bedrooms' => @vehicle&.bedrooms.presence || @variant&.beds, 'bathrooms' => (@vehicle&.bathrooms.presence || @variant&.baths)&.to_f,
      'square_feet' => @vehicle&.square_feet.presence || @variant&.square_feet,
      'size' => size, 'features' => Array(@vehicle&.features).map(&:to_s).reject(&:blank?).first(12),
      'tour_url' => @vehicle&.virtual_tour_url.presence || @vehicle&.matterport_url.presence || @variant&.media.to_h['matterport_url'],
      'photos' => photos.first(12), 'floor_plans' => plans.first(2)
    }
    facts['photos'].any? || facts['floor_plans'].any? || facts['bedrooms'] ? facts.compact : nil
  end

  private

  def title
    return [@vehicle.year, @vehicle.make, @vehicle.model].compact.join(' ') if @vehicle

    [@variant.manufacturer&.name, @variant.catalog_plan&.name, @variant.model_number].compact.join(' ')
  end

  def size
    w = @vehicle&.width.presence || @variant&.width_ft
    l = @vehicle&.length.presence || @variant&.length_ft
    w && l ? "#{w.to_i}' x #{l.to_i}'" : nil
  end

  def catalog(key)
    list = Array(@variant&.media.to_h[key])
    list = list.reject { |p| Array(@variant.media.to_h['hidden_photos']).include?(p.is_a?(Hash) ? p['url'] : p) } if key == 'photos'
    urls(list)
  end

  # Stored as strings or { 'url' => ... }; relative uploads become absolute.
  def urls(entries)
    base = ENV['RAILS_API_URL'].presence&.chomp('/')
    Array(entries).filter_map do |e|
      url = e.is_a?(Hash) ? (e['url'] || e[:url]) : e
      next if url.blank?

      url.to_s.start_with?('http') || base.nil? ? url.to_s : "#{base}#{url}"
    end
  end
end
