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

    # @param rates [Hash{String=>Float}] output of #rates
    # @param threshold [Numeric]
    # @param untracked [Array<String>] field names to exclude from the check
    #   (per-source escape hatch for fields the site genuinely does not
    #   publish — e.g. Tru has no on-page description).
    # @return [Boolean] any *tracked* field below the source threshold
    def degraded?(rates, threshold, untracked: [])
      skip = Array(untracked).map(&:to_s).to_set
      rates.any? { |field, rate| !skip.include?(field.to_s) && rate.to_f < threshold.to_f }
    end
  end
end
