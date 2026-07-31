# frozen_string_literal: true

module Catalog
  # Maps a CatalogSource's adapter_type to its adapter class. Adding support for
  # a new PLATFORM TYPE = one entry here + one adapter class. Adding a new
  # manufacturer on an existing platform = a new CatalogSource row, no code.
  #
  # Class names are resolved lazily (constantize) so Zeitwerk reloading in
  # development doesn't bind stale constants.
  module AdapterRegistry
    ADAPTERS = {
      'champion_feed'              => 'Catalog::Adapters::ChampionFeedAdapter',
      'manufacturedhomes_platform' => 'Catalog::Adapters::ManufacturedHomesPlatformAdapter',
      'avada_sitemap'              => 'Catalog::Adapters::AvadaSitemapAdapter',
      'tru_model_line'             => 'Catalog::Adapters::TruModelLineAdapter',
      'clayton_epic_region'        => 'Catalog::Adapters::ClaytonEpicRegionAdapter',
      'clayton_retail_home_center' => 'Catalog::Adapters::ClaytonRetailHomeCenterAdapter',
      'trove_catalog'              => 'Catalog::Adapters::TroveCatalogAdapter'
    }.freeze

    module_function

    # @return [Catalog::Adapters::BaseAdapter, nil] adapter instance, or nil for
    #   an unknown adapter_type (Surface B "no matching adapter — needs build").
    def for(source)
      class_name = ADAPTERS[source.adapter_type]
      return nil unless class_name

      class_name.constantize.new(source)
    end

    def supported?(adapter_type)
      ADAPTERS.key?(adapter_type)
    end

    def adapter_types
      ADAPTERS.keys
    end
  end
end
