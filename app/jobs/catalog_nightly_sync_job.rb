# frozen_string_literal: true

# Nightly dispatcher (wakes at 1am via config/recurring.yml): enqueues a run for
# each enabled CatalogSource that is DUE per its own cadence (daily / weekly /
# manual). Manual sources never auto-run. Mirrors ChampionImsWeeklySyncJob's
# due_for_sync pattern.
class CatalogNightlySyncJob < ApplicationJob
  queue_as :default

  def perform
    CatalogSource.enabled.find_each do |source|
      next unless source.due?

      CatalogSourceRunJob.perform_later(source.id, trigger: 'scheduled')
    end
  end
end
