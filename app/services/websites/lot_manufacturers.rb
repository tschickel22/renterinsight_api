# frozen_string_literal: true

module Websites
  # Which manufacturers a lot actually sells.
  #
  # The logo showcase block ships all five marks we host — Clayton, Champion,
  # TRU, Cavco, Fleetwood — on every template, for every dealer. A dealer who
  # sells only Clayton and TRU was advertising two competitors they have no
  # relationship with, on their own site.
  #
  # Read from the stock the lot is actually carrying, so it follows the catalog
  # feeds without anyone maintaining a second list. Feed-fed inventory lands as
  # available_to_order, which is why both statuses count: filtering to
  # 'available' would show nothing at all for a lot that sells to order.
  class LotManufacturers
    SELLABLE_STATUSES = %w[available available_to_order].freeze
    MAX = 12

    def self.for(company)
      new(company).call
    end

    def initialize(company)
      @company = company
    end

    # @return [Array<String>] manufacturer names, most stocked first
    def call
      return [] if @company.nil?

      counts = @company.vehicles
                       .where(status: SELLABLE_STATUSES, is_deleted: [false, nil])
                       .where.not(make: [nil, ''])
                       .group(:make)
                       .count

      counts.sort_by { |make, n| [-n, make.to_s] }.first(MAX).map { |make, _| make.to_s.strip }
    rescue StandardError => e
      # An empty list means "we could not tell", and the caller falls back to
      # showing the full set — the behaviour before this existed.
      Rails.logger.warn("[Websites::LotManufacturers] lookup failed for #{@company&.id}: #{e.message}")
      []
    end
  end
end
