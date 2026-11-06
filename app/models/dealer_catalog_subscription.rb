# frozen_string_literal: true

# Dealer opt-in (Surface A): a company elects to pull a vetted CatalogSource's
# homes into its own inventory. Catalog runs ingest into each enabled
# subscription's company, riding the existing Vehicle inventory path.
#
# location_ids controls WHERE the homes appear:
#   []        -> all locations (company-wide; ingested with location_id = nil)
#   [3, 5]    -> only those locations (one Vehicle copy per location)
#
# Which homes (backlog E94): a dealer can leave some of a feed's homes out
# (left_out_keys), and choose whether a home new to the feed is added at once
# (new_homes "add", the default) or held until they decide ("hold"). The
# homes they have already decided on are reviewed_keys, so "hold" knows which
# ones are new. Keys are the source's own (catalog_source_key).
class DealerCatalogSubscription < ApplicationRecord
  NEW_HOMES = %w[add hold].freeze

  belongs_to :company
  belongs_to :catalog_source

  validates :catalog_source_id, uniqueness: { scope: :company_id }
  validates :new_homes, inclusion: { in: NEW_HOMES }

  scope :enabled, -> { where(enabled: true) }

  # Locations to ingest into. Empty selection => [nil] (one company-wide copy);
  # otherwise one copy per chosen location id.
  def ingest_location_ids
    ids = Array(location_ids).map(&:to_i).uniq
    ids.empty? ? [nil] : ids
  end

  def hold_new? = new_homes == 'hold'

  # Whether the dealer carries this home: not left out, and, while new homes
  # are held, one they have already decided on.
  def wants?(key)
    key = key.to_s
    return false if left_out_set.include?(key)

    !hold_new? || reviewed_set.include?(key)
  end

  # A home in the feed the dealer has not decided on yet, while held.
  def waiting?(key)
    hold_new? && !left_out_set.include?(key.to_s) && !reviewed_set.include?(key.to_s)
  end

  # The dealer's decision over the homes they were shown: the ones not kept
  # are left out, every one shown is reviewed. Homes not shown keep whatever
  # was decided before.
  def choose!(shown_keys:, kept_keys:, new_homes: self.new_homes)
    shown = shown_keys.map(&:to_s).uniq
    kept = kept_keys.map(&:to_s).to_set
    self.left_out_keys = ((Array(left_out_keys).map(&:to_s) - shown) + shown.reject { |k| kept.include?(k) }).uniq
    self.reviewed_keys = (Array(reviewed_keys).map(&:to_s) | shown)
    self.new_homes = new_homes
    save!
  end

  private

  def left_out_set = Array(left_out_keys).map(&:to_s).to_set
  def reviewed_set = Array(reviewed_keys).map(&:to_s).to_set
end
