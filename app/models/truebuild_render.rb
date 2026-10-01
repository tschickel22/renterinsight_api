# frozen_string_literal: true

# A TrueView rendering: one source photo, redrawn by one image model in one
# selection of finishes. Platform data, like the catalog it draws from.
class TruebuildRender < ApplicationRecord
  # skipped: a layer for a surface the photo does not show; nothing drawn.
  # flagged: a reviewer marked it wrong; buyers stop seeing it and a redraw
  # with their note replaces it. superseded: replaced after a re-outline.
  STATUSES = %w[queued running done failed skipped flagged superseded].freeze

  belongs_to :catalog_plan_variant, optional: true

  validates :source_url, :selection_key, :model_key, :provider, :model, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :done, -> { where(status: 'done') }

  # The same finishes in any order are the same rendering.
  def self.key_for(selection)
    Digest::SHA256.hexdigest(normalize(selection).to_json)[0, 32]
  end

  def self.normalize(selection)
    Array(selection).map { |f| { 'surface' => f['surface'].to_s.strip, 'value' => f['value'].to_s.strip } }
                    .reject { |f| f['surface'].empty? || f['value'].empty? }
                    .sort_by { |f| [f['surface'].downcase, f['value'].downcase] }
  end
end
