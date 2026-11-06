# frozen_string_literal: true

module Catalog
  # Moves a dealer from one catalog source to others that publish the same
  # homes under the same keys, without re-creating a single home (backlog E94).
  #
  # Easy Homesource took Cavco's homes through their retailer assignment
  # (cavco_retailer), which leaves out models their plants build. The plant
  # sources (cavco_plant) carry every model, keyed by the same Cavco floorplan
  # id. Unsubscribing and subscribing again would soft-delete the dealer's 99
  # homes and add new rows: their edits, photos, deals and website links would
  # point at deleted homes. Re-pointing the rows keeps every one.
  #
  # Each target needs a parse (ParsedHomeCache) to say which keys it carries.
  # A home no target carries stays on the old source; the old subscription is
  # removed only when none is left, so nothing is ever deleted here.
  module SubscriptionMove
    module_function

    Error = Class.new(StandardError)

    # @param new_homes ['add', 'hold'] for each new subscription. Every home
    #   moved counts as reviewed and kept.
    # @param dry_run [Boolean] report what would move, change nothing.
    # @return [Hash] moved per target id, left behind, old subscription removed?
    def call(company:, from:, to:, new_homes: 'add', dry_run: false)
      old_sub = company.dealer_catalog_subscriptions.find_by(catalog_source_id: from.id)
      raise Error, "#{company.name} has no subscription to #{from.name}" unless old_sub

      targets = Array(to).to_h do |source|
        homes = ParsedHomeCache.read(source, max_age: HomeChoice::LIST_AGE)
        raise Error, "#{source.name} has no parse yet. Run it once first." if homes.blank?

        [source, homes.map { |h| h.source_key.to_s }.to_set]
      end
      rows = company.vehicles.where(catalog_source_id: from.id).to_a
      plan = rows.group_by { |v| targets.find { |_, keys| keys.include?(v.catalog_source_key.to_s) }&.first }
      left = Array(plan.delete(nil))
      report = { moved: plan.to_h { |s, vs| [s.id, vs.size] }, left_behind: left.map(&:catalog_source_key), old_removed: left.empty? }
      return report if dry_run

      ActiveRecord::Base.transaction do
        targets.each do |source, keys|
          sub = company.dealer_catalog_subscriptions.find_or_initialize_by(catalog_source_id: source.id)
          sub.assign_attributes(enabled: true, location_ids: old_sub.location_ids, new_homes: new_homes)
          moving = Array(plan[source]).map { |v| v.catalog_source_key.to_s }
          # The homes they had are decided on; with new homes held, the rest
          # of the plant's homes wait for the dealer.
          sub.reviewed_keys = (Array(sub.reviewed_keys).map(&:to_s) | moving)
          sub.reviewed_keys |= keys.to_a if new_homes == 'add'
          sub.save!
          # Content hash cleared: the next run rewrites what the new source
          # says, under the usual rules that keep a dealer's own edits.
          Vehicle.where(id: Array(plan[source]).map(&:id)).update_all(catalog_source_id: source.id, catalog_content_hash: nil)
        end
        old_sub.destroy! if left.empty?
      end
      report
    end
  end
end
