# frozen_string_literal: true

module Catalog
  # Computes per-field extraction rates across a batch of NormalizedHome objects.
  # Shared by RunService (full run) and the admin "Test" action (dry-run sample),
  # so the health math is identical in both places.
  module ExtractionStats
    module_function

    # @param homes [Array<NormalizedHome>]
    # @return [Hash{String=>Float}] field => fraction populated (0.0..1.0), 4dp
    def rates(homes)
      total = Hash.new(0)
      hits  = Hash.new(0)

      homes.each do |home|
        home.field_presence.each do |field, present|
          total[field] += 1
          hits[field]  += 1 if present
        end
      end

      total.keys.index_with do |field|
        total[field].zero? ? 0.0 : (hits[field].to_f / total[field]).round(4)
      end
    end

    # @return [Boolean] any tracked field below the source threshold
    def degraded?(rates, threshold)
      rates.values.any? { |rate| rate.to_f < threshold.to_f }
    end
  end
end
