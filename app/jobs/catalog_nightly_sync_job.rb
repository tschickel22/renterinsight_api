# frozen_string_literal: true

# Nightly dispatcher: enqueues a run for every enabled CatalogSource.
# Wired in config/recurring.yml. Mirrors ChampionImsWeeklySyncJob.
class CatalogNightlySyncJob < ApplicationJob
  queue_as :default

  def perform
    CatalogSource.enabled.find_each do |source|
      CatalogSourceRunJob.perform_later(source.id, trigger: 'scheduled')
    end
  end
end
