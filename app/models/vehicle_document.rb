# frozen_string_literal: true

# VehicleDocument — per-vehicle document with explicit visibility tier.
#
# Visibility is the enforcement contract for public/portal exposure:
#   - 'internal' (default, safest): staff only
#   - 'customer': linked buyer can see in the buyer portal
#   - 'public':   visible on public inventory surfaces (rare — factory docs
#                  travel with the home but should NOT be public by default)
#
# Anything reading documents on a customer-facing surface MUST filter by
# visibility — never expose the raw association without the scope.
class VehicleDocument < ApplicationRecord
  VISIBILITIES = %w[internal customer public].freeze
  CATEGORIES   = %w[factory title registration inspection warranty service other].freeze

  belongs_to :vehicle
  belongs_to :uploaded_by_user, class_name: 'User', optional: true

  validates :title,      presence: true, length: { maximum: 255 }
  validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
  validates :category,   presence: true, inclusion: { in: CATEGORIES }

  scope :internal,         -> { where(visibility: 'internal') }
  scope :customer_visible, -> { where(visibility: %w[customer public]) }
  scope :public_visible,   -> { where(visibility: 'public') }
end
