# frozen_string_literal: true

require 'digest'

module Catalog
  # The single internal schema every adapter emits. Champion, ManufacturedHomes
  # platform, and Avada sitemap all converge here, then ride the shared
  # ingestion path. This is a plain value object — no persistence.
  class NormalizedHome
    # Fields whose extraction we track for the per-field health signal. A scrape
    # "succeeds" on a field when its extractor returns a non-blank value; the
    # rate of success across all homes is the early-warning degradation metric.
    TRACKED_FIELDS = %w[
      model_name model_id series property_type bedrooms bathrooms
      dimensions square_feet description images
    ].freeze

    ATTRS = %i[
      source_key source_url model_name model_id series property_type
      bedrooms bathrooms dimensions square_feet description features
      images virtual_tour_url price_quote_url raw
    ].freeze

    attr_accessor(*ATTRS)

    def initialize(**attrs)
      attrs.each { |k, v| public_send("#{k}=", v) if respond_to?("#{k}=") }
      @features      ||= {}
      @images        ||= []
      @property_type ||= []
      @raw           ||= {}
    end

    # Stable hash over the meaningful content — drives change detection between
    # runs (only re-ingest / flag when content actually changed).
    def content_hash
      payload = TRACKED_FIELDS.index_with { |f| public_send(f) }
      payload['images'] = image_source_urls.sort
      Digest::SHA256.hexdigest(payload.to_json)
    end

    # field name => boolean (did the extractor produce a non-blank value?)
    def field_presence
      TRACKED_FIELDS.index_with { |f| present_value?(public_send(f)) }
    end

    # Per-run smoke test: every home should yield a name + bed/bath/sqft + ≥1 image.
    def valid_smoke?
      model_name.present? && bedrooms.present? && bathrooms.present? &&
        square_feet.present? && images.any?
    end

    def image_source_urls
      Array(images).map { |i| i.is_a?(Hash) ? (i['source_url'] || i[:source_url] || i['url'] || i[:url]) : i }.compact
    end

    def floorplan_images
      Array(images).select { |i| i.is_a?(Hash) && (i['is_floorplan'] || i[:is_floorplan]) }
    end

    private

    def present_value?(value)
      case value
      when nil          then false
      when Array, Hash  then value.any?
      when String       then value.strip.present?
      else true
      end
    end
  end
end
