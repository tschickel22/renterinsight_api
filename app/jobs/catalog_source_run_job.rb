# frozen_string_literal: true

# Runs one CatalogSource through Catalog::RunService. Enqueued by the admin
# "Run Now" action and by the nightly dispatcher.
class CatalogSourceRunJob < ApplicationJob
  queue_as :default

  def perform(catalog_source_id, trigger: 'scheduled')
    source = CatalogSource.active.find_by(id: catalog_source_id)
    return if source.nil?

    Catalog::RunService.new(source, trigger: trigger).call
  end
end
