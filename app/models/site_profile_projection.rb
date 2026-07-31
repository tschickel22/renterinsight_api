# frozen_string_literal: true

# One template filled with one profile's content.
#
# Cheap and regenerable — kept mainly so an optional AI polish pass and its
# refine lineage have somewhere to live, and so a committed projection records
# which website it produced.
class SiteProfileProjection < ApplicationRecord
  belongs_to :site_content_profile
  belongs_to :website, optional: true
  belongs_to :parent, class_name: 'SiteProfileProjection', optional: true

  has_many :refinements, class_name: 'SiteProfileProjection', foreign_key: :parent_id, dependent: :nullify

  validates :template_id, presence: true

  scope :committed, -> { where.not(website_id: nil) }

  def committed?
    website_id.present?
  end
end
