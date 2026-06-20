# frozen_string_literal: true

# Deterministic adapter for catalog specs — no network. Yields a fixed set of
# NormalizedHome objects so RunService / extraction-rate behavior is testable.
class FakeCatalogAdapter
  def initialize(homes)
    @homes = homes
  end

  def discover(limit: nil)
    keys = @homes.map(&:source_key)
    limit ? keys.first(limit) : keys
  end

  def fetch(key)
    @homes.find { |h| h.source_key == key }
  end

  def parse(raw)
    raw # fetch already returns the NormalizedHome
  end

  def crawl_delay
    0
  end

  def sample(limit: 5)
    @homes.first(limit)
  end

  # Helper to build a fully-populated home (overridable per field).
  def self.home(key, **overrides)
    Catalog::NormalizedHome.new(
      **{
        source_key:   key,
        source_url:   "https://example-homes.com/floor-plan-detail/#{key}/",
        model_name:   "Model #{key}",
        model_id:     "MOD#{key}",
        series:       'Prime',
        property_type: %w[Manufactured],
        bedrooms:     3,
        bathrooms:    '2',
        dimensions:   "30'0\" x 80'0\"",
        square_feet:  2200,
        description:  'A lovely home.',
        features:     { 'Kitchen' => ['Island'] },
        images:       [{ 'source_url' => "https://cdn/#{key}.jpg", 'alt' => 'front', 'is_floorplan' => false }]
      }.merge(overrides)
    )
  end
end
