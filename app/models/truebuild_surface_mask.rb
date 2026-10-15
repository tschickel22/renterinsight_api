# frozen_string_literal: true

# Where one surface sits in one photo (Truebuild::Trueview::Surfaces).
class TruebuildSurfaceMask < ApplicationRecord
  validates :source_url, :surface, presence: true
  validates :status, inclusion: { in: %w[done failed] }

  # The photo shows this surface: enough of it to paint.
  def present?
    status == 'done' && mask_url.present? && coverage.to_f >= Truebuild::Trueview::Surfaces.min_present(key)
  end

  # The surface without a trial outline's painter ("siding@nb2" is siding).
  def key = surface.to_s.split('@').first
end
