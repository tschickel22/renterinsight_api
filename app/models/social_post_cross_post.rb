# frozen_string_literal: true

# The blog version of a SocialPost. See the migration for what each status means.
class SocialPostCrossPost < ApplicationRecord
  STATUSES     = %w[pending skipped published failed].freeze
  DESTINATIONS = %w[website_builder marketing_site].freeze

  belongs_to :company
  belongs_to :social_post
  belongs_to :website, optional: true

  validates :status,      inclusion: { in: STATUSES }
  validates :destination, inclusion: { in: DESTINATIONS }


  def pending?   = status == 'pending'
  def published? = status == 'published'

  def written?
    title.present? && content.present?
  end

  # Live on the site with an address to link to.
  def linkable?
    published? && public_url.present? && error.blank?
  end

  def publisher
    destination == 'marketing_site' ? SocialBlog::MarketingSitePublisher : SocialBlog::WebsiteBuilderPublisher
  end
end
