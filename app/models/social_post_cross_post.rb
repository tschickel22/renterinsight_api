# frozen_string_literal: true

# The blog version of a SocialPost. See the migration for what each status means.
class SocialPostCrossPost < ApplicationRecord
  STATUSES     = %w[pending skipped published failed].freeze
  DESTINATIONS = %w[website_builder].freeze

  belongs_to :company
  belongs_to :social_post
  belongs_to :website, optional: true

  validates :status,      inclusion: { in: STATUSES }
  validates :destination, inclusion: { in: DESTINATIONS }

  scope :blog, -> { where(destination: 'website_builder') }

  def pending?   = status == 'pending'
  def published? = status == 'published'

  def written?
    title.present? && content.present?
  end
end
