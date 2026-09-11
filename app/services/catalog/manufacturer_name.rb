# frozen_string_literal: true

module Catalog
  # The manufacturer to write on a home pulled from a catalog.
  #
  # A source is named for the operator who manages it — "Clayton — Acme Homes,
  # Llc (Monroe, NC)" says which feed, whose dealership and where, which is
  # exactly what a platform admin needs in a list of thirty sources. Written to
  # a home's make, the same string reads as "2026 Clayton — Acme Homes, Llc
  # (Monroe, NC) EMILIE ELITE" on every listing card, and the city in it is the
  # retailer's, not the home's. Asked where that address came from, nobody could
  # tell: it is not an address field at all.
  #
  # Resolved in order of how much each source of truth actually knows:
  #
  #   the home's own brand, where a feed publishes one (Cavco does)
  #   an explicit manufacturer_name on the source, set by an admin
  #   the manufacturer the adapter is built for, which is most of them
  #   the operator's label up to where their own note begins
  #
  # Never nil: a make is required, and the whole source name — wrong as it reads
  # — beats an empty one.
  class ManufacturerName
    # Adapters written against one manufacturer's own systems. The generic
    # platform adapters (trove_catalog, avada_sitemap,
    # manufacturedhomes_platform) carry homes from many builders and are
    # deliberately absent: for those the source's name is the only clue.
    BY_ADAPTER = {
      'clayton_epic_region' => 'Clayton',
      'clayton_retail_home_center' => 'Clayton',
      'cavco_retailer' => 'Cavco',
      'champion_feed' => 'Champion',
      'tru_model_line' => 'TRU',
      'adventure_homes' => 'Adventure Homes',
      'timber_creek_dealer' => 'Timber Creek'
    }.freeze

    # Where a manufacturer's name stops and an operator's note begins. A dash or
    # pipe with space around it, or a bracket, comma or slash: every separator
    # our own source names actually use, and none that appear inside a builder's
    # name.
    NOTE_BEGINS = /\s+[—–|:]\s+|\s+-\s+|\s*[(\[,\/]/

    def self.for(source, brand: nil)
      new(source, brand: brand).call
    end

    def initialize(source, brand: nil)
      @source = source
      @brand = brand
    end

    def call
      @brand.presence ||
        config_name ||
        BY_ADAPTER[@source&.adapter_type.to_s] ||
        leading_segment ||
        @source&.name.presence
    end

    private

    def config_name
      @source&.config.is_a?(Hash) ? @source.config['manufacturer_name'].presence : nil
    end

    # "Clayton — Acme Homes, Llc (Monroe, NC)" -> "Clayton".
    # "Adventure Homes" -> nil, since there is nothing to cut and the caller
    # already has the name.
    def leading_segment
      name = @source&.name.to_s
      head = name.split(NOTE_BEGINS).first.to_s.strip
      return nil if head.blank? || head == name.strip

      head
    end
  end
end
