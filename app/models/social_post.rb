# frozen_string_literal: true

class SocialPost < ApplicationRecord
  include WebhookNotifiable

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :social_account, optional: true
  belongs_to :vehicle, optional: true
  belongs_to :created_by_user, class_name: 'User', optional: true
  belongs_to :approved_by, class_name: 'User', foreign_key: :approved_by_id, optional: true
  belongs_to :nurture_sequence, optional: true

  has_many :leads, foreign_key: :social_post_id, dependent: :nullify
  has_many :social_comments, dependent: :destroy
  # One blog version per post, on a website-builder site or one of our own
  # marketing sites.
  has_one  :blog_cross_post, -> { where(destination: %w[website_builder marketing_site]) },
           class_name: 'SocialPostCrossPost', dependent: :destroy

  # The blog version goes out when the social post does. Publishing happens in
  # two places (the controller's Publish button and PublishSocialPostJob), so
  # the hook sits here where both end up.
  after_update_commit :publish_blog_version, if: -> { saved_change_to_status?(to: 'published') }

  scope :active,    -> { where(is_deleted: [false, nil]) }
  scope :published, -> { where(status: 'published') }
  scope :scheduled, -> { where(status: 'scheduled') }

  private

  def publish_blog_version
    return unless blog_cross_post&.pending?

    PublishSocialBlogJob.perform_later(id)
  end
end
